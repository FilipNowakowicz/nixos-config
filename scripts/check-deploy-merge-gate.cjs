// Fail closed: require the successful PR workflow's own merge-gate job.
//
// A PR merged before its nix.yml run finishes (e.g. an admin merge) would
// otherwise race this check. While a matching PR run is still pending, poll
// until it completes or the timeout passes; with nothing pending, fail at once.
//
// A newer main commit is not a failure when that push starts its own deploy,
// which carries this commit's changes too. The check sets output `current` to
// false and returns, the workflow skips every later step, and the superseded
// run ends green with a notice instead of red. Every other refusal still throws.
//
// A newer commit only starts a deploy if it touches the workflow's `paths`
// filter. When nothing between this commit and main does, no newer run is
// coming, so this one carries on and deploys: the homeserver closure is the
// same at both commits.
const PENDING = new Set([
  "queued",
  "in_progress",
  "waiting",
  "requested",
  "pending",
]);

// Mirrors `on.push.paths` in .github/workflows/deploy-homeserver.yml;
// scripts/test-deploy-merge-gate.cjs fails if the two drift apart.
const DEPLOY_PATHS = [
  "hosts/homeserver-gcp/**",
  "modules/**",
  "lib/**",
  "home/**",
  "flake.nix",
  "flake.lock",
  "flake/**",
  "scripts/**",
  ".github/workflows/deploy-homeserver.yml",
  ".github/actions/setup-nix/**",
];

const matchesDeployPath = (file) =>
  DEPLOY_PATHS.some((pattern) =>
    pattern.endsWith("/**")
      ? file.startsWith(pattern.slice(0, -2))
      : file === pattern,
  );

// Whether a push run will deploy the newer main: true if any commit after
// ours touches the deploy paths, or if the comparison cannot tell.
async function newerRunDeploys(github, owner, repo, base, head) {
  const compare = await github.rest.repos.compareCommitsWithBasehead({
    owner,
    repo,
    basehead: `${base}...${head}`,
    per_page: 300,
  });
  const files = compare.data.files || [];
  // The API lists at most 300 files; beyond that, assume a deploy follows.
  if (compare.data.status !== "ahead" || files.length >= 300) return true;
  return files.some(
    (f) =>
      matchesDeployPath(f.filename) ||
      (f.previous_filename && matchesDeployPath(f.previous_filename)),
  );
}

const checkDeployMergeGate = async ({
  github,
  context,
  core,
  pollMs = 30_000,
  timeoutMs = 60 * 60_000,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}) => {
  const { owner, repo } = context.repo;
  const commit_sha = context.sha;
  const deadline = Date.now() + timeoutMs;

  for (;;) {
    const latest = await github.rest.repos.getBranch({
      owner,
      repo,
      branch: "main",
    });
    if (
      latest.data.commit.sha !== commit_sha &&
      (await newerRunDeploys(
        github,
        owner,
        repo,
        commit_sha,
        latest.data.commit.sha,
      ))
    ) {
      core.notice(
        `Skipping deploy: main moved on to ${latest.data.commit.sha}, whose own run deploys these changes`,
      );
      core.setOutput("current", "false");
      return false;
    }
    const pulls = await github.paginate(
      github.rest.repos.listPullRequestsAssociatedWithCommit,
      { owner, repo, commit_sha, per_page: 100 },
    );
    const candidates = pulls.filter(
      (pr) =>
        pr.merged_at &&
        pr.merge_commit_sha === commit_sha &&
        pr.base.ref === "main" &&
        pr.base.repo.full_name === context.payload.repository.full_name &&
        pr.head.repo?.full_name === context.payload.repository.full_name,
    );
    let pending = false;
    for (const pr of candidates) {
      const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
        owner,
        repo,
        workflow_id: "nix.yml",
        head_sha: pr.head.sha,
        event: "pull_request",
        per_page: 100,
      });
      for (const run of runs) {
        if (
          run.head_sha !== pr.head.sha ||
          run.event !== "pull_request" ||
          run.path !== ".github/workflows/nix.yml"
        )
          continue;
        if (PENDING.has(run.status)) {
          pending = true;
          continue;
        }
        if (run.conclusion !== "success") continue;
        const jobs = await github.paginate(
          github.rest.actions.listJobsForWorkflowRunAttempt,
          {
            owner,
            repo,
            run_id: run.id,
            attempt_number: run.run_attempt,
            per_page: 100,
          },
        );
        if (
          jobs.some(
            (job) =>
              job.name === "merge-gate" &&
              job.status === "completed" &&
              job.conclusion === "success",
          )
        ) {
          core.info(`Verified PR #${pr.number} merge-gate for ${commit_sha}`);
          core.setOutput("current", "true");
          return true;
        }
      }
    }
    if (!pending)
      throw new Error(
        "Cannot establish a successful PR merge-gate for this exact main commit",
      );
    if (Date.now() + pollMs > deadline)
      throw new Error("Timed out waiting for the PR merge-gate to finish");
    core.info("PR nix.yml run still in progress; waiting for merge-gate");
    await sleep(pollMs);
  }
};

module.exports = checkDeployMergeGate;
module.exports.DEPLOY_PATHS = DEPLOY_PATHS;
