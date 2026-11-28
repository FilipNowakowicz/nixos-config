const assert = require("node:assert/strict");
const check = require("./check-deploy-merge-gate.cjs");
const repo = "owner/repo";
let outputs = {};
async function run(overrides = {}, options = {}) {
  outputs = {};
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
    // Files changed between this commit and a newer main; by default they
    // touch the homeserver, so the newer push deploys on its own.
    compare: {
      status: "ahead",
      files: [{ filename: "hosts/homeserver-gcp/x.nix" }],
    },
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
        compareCommitsWithBasehead: async () => ({ data: data.compare }),
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
    core: {
      info() {},
      notice() {},
      setOutput: (name, value) => (outputs[name] = value),
    },
    pollMs: 1,
    timeoutMs: 1_000,
    sleep: async () => {},
    ...options,
  });
}
(async () => {
  assert.equal(await run(), true);
  assert.equal(outputs.current, "true");

  // A newer main commit skips (its own run deploys these changes); it does
  // not fail, and it never reports itself as current.
  assert.equal(await run({ latest: "newer" }), false);
  assert.equal(outputs.current, "false");

  for (const overrides of [
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
  assert.equal(
    await run({
      runs: [inProgress],
      latest: () => (branchReads++ < 1 ? "merged" : "newer"),
    }),
    false,
  );
  assert.equal(outputs.current, "false");
  // A newer commit outside the deploy paths starts no deploy of its own, so
  // this run carries on and deploys.
  assert.equal(
    await run({
      latest: "newer",
      compare: {
        status: "ahead",
        files: [{ filename: "packages/quiet-shell/x.qml" }],
      },
    }),
    true,
  );
  assert.equal(outputs.current, "true");
  // A rename out of the deploy paths still counts as touching them.
  assert.equal(
    await run({
      latest: "newer",
      compare: {
        status: "ahead",
        files: [{ filename: "docs/x.md", previous_filename: "lib/x.nix" }],
      },
    }),
    false,
  );

  // The script's path list matches the workflow's push filter.
  const yml = require("node:fs").readFileSync(
    ".github/workflows/deploy-homeserver.yml",
    "utf8",
  );
  const block = yml
    .split("\n    paths:\n")[1]
    .split("\n  workflow_dispatch:")[0];
  const workflowPaths = block
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith("- "))
    .map((l) => l.slice(2));
  assert.deepEqual(check.DEPLOY_PATHS, workflowPaths);

  console.log("Deployment merge-gate fail-closed and superseded cases passed");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
