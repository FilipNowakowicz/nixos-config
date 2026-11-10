// Fail closed: require the successful PR workflow's own merge-gate job.
//
// A PR merged before its nix.yml run finishes (e.g. an admin merge) would
// otherwise race this check. While a matching PR run is still pending, poll
// until it completes or the timeout passes; with nothing pending, fail at once.
const PENDING = new Set([
  "queued",
  "in_progress",
  "waiting",
  "requested",
  "pending",
]);

module.exports = async ({
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
    if (latest.data.commit.sha !== commit_sha)
      throw new Error("Refusing a stale main commit");
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
          return;
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
