// Fail closed: require the successful PR workflow's own merge-gate job.
module.exports = async ({ github, context, core }) => {
  const { owner, repo } = context.repo;
  const commit_sha = context.sha;
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
  for (const pr of candidates) {
    const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
      owner,
      repo,
      workflow_id: "nix.yml",
      head_sha: pr.head.sha,
      event: "pull_request",
      status: "success",
      per_page: 100,
    });
    for (const run of runs) {
      if (
        run.head_sha !== pr.head.sha ||
        run.event !== "pull_request" ||
        run.conclusion !== "success" ||
        run.path !== ".github/workflows/nix.yml"
      )
        continue;
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
  throw new Error(
    "Cannot establish a successful PR merge-gate for this exact main commit",
  );
};
