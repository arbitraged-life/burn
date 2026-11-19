#!/usr/bin/env bash
# Run only from the fork's trusted default branch; never execute upstream code here.
set -euo pipefail
: "${GH_REPO:?}" "${UPSTREAM_REPO:?}" "${TARGET_BRANCH:?}" "${GITHUB_OUTPUT:?}" "${GITHUB_STEP_SUMMARY:?}"

git fetch --no-tags origin "$TARGET_BRANCH"
base_sha=$(git rev-parse FETCH_HEAD)
# Keep one pending proposal instead of producing a new PR for every upstream commit.
existing=$(gh pr list --repo "$GH_REPO" --base "$TARGET_BRANCH" --state open --limit 100 \
  --json number,url,headRefName,headRefOid,isCrossRepository | jq -c '[.[] | select(.isCrossRepository == false) | select(.headRefName | startswith("upstream-sync/"))][0] // empty')
if [[ -n "$existing" ]]; then
  head_sha=$(jq -r .headRefOid <<< "$existing")
  url=$(jq -r .url <<< "$existing")
else
  git fetch --no-tags "https://github.com/$UPSTREAM_REPO.git" main
  head_sha=$(git rev-parse FETCH_HEAD)
  if git merge-base --is-ancestor "$head_sha" "$base_sha"; then
    echo "Upstream main is already included in $TARGET_BRANCH." >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
  branch="upstream-sync/$head_sha"
  previous=$(gh pr list --repo "$GH_REPO" --base "$TARGET_BRANCH" --head "$branch" \
    --state all --limit 1 --json url --jq '.[0].url // empty')
  if [[ -n "$previous" ]]; then
    echo "This upstream revision already had a proposal: $previous. Reopen it to reconsider; no duplicate created." >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
  # A new immutable branch: no force-push, target update, tag, or release.
  git push --no-follow-tags origin "$head_sha:refs/heads/$branch"
  url=$(gh pr create --repo "$GH_REPO" --base "$TARGET_BRANCH" --head "$branch" \
    --title "Sync upstream main (${head_sha:0:12}) into $TARGET_BRANCH" \
    --body "Upstream: https://github.com/$UPSTREAM_REPO/commit/$head_sha

This proposal preserves the customized target branch. Review and merge manually; there is no automatic approval or merge. Merge conflicts require manual resolution.

Validation runs in this scheduled workflow, not automatically as a PR-triggered workflow (GitHub suppresses those events for GITHUB_TOKEN-created PRs): https://github.com/$GH_REPO/actions/runs/$GITHUB_RUN_ID

Use the **Scheduled upstream sync** manual run to recheck the current target against this open proposal. Closing the PR declines this exact upstream revision; a later revision can produce a new proposal.")
fi
printf 'base_sha=%s\nhead_sha=%s\n' "$base_sha" "$head_sha" >> "$GITHUB_OUTPUT"
printf 'Proposal: %s\n\nValidation below checks target `%s` against proposed upstream `%s`.\n' "$url" "$base_sha" "$head_sha" >> "$GITHUB_STEP_SUMMARY"
