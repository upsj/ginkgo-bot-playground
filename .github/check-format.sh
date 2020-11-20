#!/bin/bash

source $(dirname "${BASH_SOURCE[0]}")/bot-base.sh

echo -n "Collecting information on triggering PR"
PR_URL=$(jq -r .pull_request.url "$GITHUB_EVENT_PATH")
if [[ "$PR_URL" == "null" ]]; then
  echo -n ........
  PR_URL=$(jq -er .issue.pull_request.url "$GITHUB_EVENT_PATH")
  echo -n .
fi
echo -n .
PR_JSON=$(api_get $PR_URL)
echo -n .
ISSUE_URL=$(echo "$PR_JSON" | jq -er ".issue_url")
echo -n .
HEAD_REPO=$(echo "$PR_JSON" | jq -er .head.repo.full_name)
echo -n .
HEAD_BRANCH=$(echo "$PR_JSON" | jq -er .head.ref)
echo .
HEAD_URL="https://${GITHUB_ACTOR}:${GITHUB_TOKEN}@github.com/$HEAD_REPO"

bot_comment() {
  api_post $ISSUE_URL/comments "{\"body\":\"$1\"}" > /dev/null
}

bot_error() {
  echo "$1"
  bot_comment "Error: $1"
  exit 1
}

git remote add fork "${HEAD_URL}"
git fetch fork "$HEAD_BRANCH"
git checkout -b format-tmp-$HEAD_BRANCH "fork/$HEAD_BRANCH"

dev_tools/scripts/add_license.sh
dev_tools/scripts/update_ginkgo_header.sh
dev_tools/scripts/format_header.sh
find benchmark common core cuda dpcpp examples hip include omp reference test_install \
  -name '*.cpp' -or -name '*.hpp' -or -name '*.cu' -or -name '*.cuh' \
  -exec clang-format-8 -i {} \;

LIST_FILES=$(git diff --name-only)

if [[ "$LIST_FILES" != "" ]]; then
  bot_error "The following files need to be formatted:\n"'```'"\n$LIST_FILES\n"'```'
  git diff
fi
