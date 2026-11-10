const assert = require("node:assert/strict");
const check = require("./check-deploy-merge-gate.cjs");
const repo = "owner/repo";
async function run(overrides = {}, options = {}) {
  const data = {
    latest: "merged",
    pulls: [
      {
        number: 1,
        merged_at: "today",
        merge_commit_sha: "merged",
        base: { ref: "main", repo: { full_name: repo } },
        head: { sha: "head", repo: { full_name: repo } },
      },
    ],
    runs: [
      {
        id: 2,
        run_attempt: 1,
        head_sha: "head",
        event: "pull_request",
        conclusion: "success",
        path: ".github/workflows/nix.yml",
      },
    ],
    jobs: [{ name: "merge-gate", status: "completed", conclusion: "success" }],
    ...overrides,
  };
  const github = {
    rest: {
      repos: {
        getBranch: async () => ({
          data: {
            commit: {
              sha:
                typeof data.latest === "function" ? data.latest() : data.latest,
            },
          },
        }),
        listPullRequestsAssociatedWithCommit: "pulls",
      },
      actions: {
        listWorkflowRuns: "runs",
        listJobsForWorkflowRunAttempt: "jobs",
      },
    },
    paginate: async (kind, args) => {
      if (kind === "runs") assert.equal(args.workflow_id, "nix.yml");
      if (kind === "jobs") assert.equal(args.attempt_number, 1);
      const value = data[kind];
      return typeof value === "function" ? value() : value;
    },
  };
  return check({
    github,
    context: {
      repo: { owner: "owner", repo: "repo" },
      sha: "merged",
      payload: { repository: { full_name: repo } },
    },
    core: { info() {} },
    pollMs: 1,
    timeoutMs: 1_000,
    sleep: async () => {},
    ...options,
  });
}
(async () => {
  await run();
  for (const overrides of [
    { latest: "newer" },
    { pulls: [] },
    { runs: [] },
    { jobs: [] },
    {
      jobs: [
        { name: "merge-gate", status: "completed", conclusion: "skipped" },
      ],
    },
    {
      runs: [
        { head_sha: "other", event: "pull_request", conclusion: "success" },
      ],
    },
    { runs: [{ head_sha: "head", event: "push", conclusion: "success" }] },
  ]) {
    await assert.rejects(run(overrides));
  }

  // A PR run still in progress at merge time is waited on, not refused.
  const done = {
    id: 2,
    run_attempt: 1,
    head_sha: "head",
    event: "pull_request",
    status: "completed",
    conclusion: "success",
    path: ".github/workflows/nix.yml",
  };
  const inProgress = { ...done, status: "in_progress", conclusion: null };
  let polls = 0;
  let sleeps = 0;
  await run(
    { runs: () => (polls++ < 2 ? [inProgress] : [done]) },
    { sleep: async () => sleeps++ },
  );
  assert.equal(sleeps, 2);

  // ...but only until the timeout, and a newer main commit still wins.
  await assert.rejects(
    run({ runs: [inProgress] }, { timeoutMs: 5 }),
    /Timed out/,
  );
  let branchReads = 0;
  await assert.rejects(
    run({
      runs: [inProgress],
      latest: () => (branchReads++ < 1 ? "merged" : "newer"),
    }),
    /stale/,
  );
  console.log("Deployment merge-gate fail-closed cases passed");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
