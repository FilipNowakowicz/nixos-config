const assert = require("node:assert/strict");
const check = require("./check-deploy-merge-gate.cjs");
const repo = "owner/repo";
async function run(overrides = {}) {
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
        getBranch: async () => ({ data: { commit: { sha: data.latest } } }),
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
      return data[kind];
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
  console.log("Deployment merge-gate fail-closed cases passed");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
