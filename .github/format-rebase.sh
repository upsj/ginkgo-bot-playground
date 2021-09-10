#!/bin/bash

source .github/bot-pr-base.sh

git remote add base "$BASE_URL"
git remote add fork "$HEAD_URL"

git remote -v

git fetch base $BASE_BRANCH
git fetch fork $HEAD_BRANCH

git config user.email "$USER_EMAIL"
git config user.name "$USER_NAME"

LOCAL_BRANCH=rebase-tmp-$HEAD_BRANCH
git checkout -b $LOCAL_BRANCH fork/$HEAD_BRANCH

# save scripts from develop
pushd dev_tools/scripts
cp add_license.sh format_header.sh update_ginkgo_header.sh /tmp
popd

bot_delete_comments_matching "Error: Rebase failed"

# do the formatting rebase
git rebase --exec "bash -c \"set -xe                                                                                 \
    cp /tmp/add_license.sh /tmp/format_header.sh /tmp/update_ginkgo_header.sh dev_tools/scripts/;                    \
    dev_tools/scripts/add_license.sh && dev_tools/scripts/update_ginkgo_header.sh;                                   \
    git checkout dev_tools/scripts;                                                                                  \
    git add .;                                                                                                       \
    for f in \\\$(git diff --name-only --cached | grep -E '\$EXTENSION_REGEX' | grep -E '\$FORMAT_HEADER_REGEX'); do \
        dev_tools/scripts/format_header.sh \\\$f;                                                                    \
        git add \\\$f;                                                                                               \
    done;                                                                                                            \
    for f in \\\$(git diff --name-only --cached | grep -E '\$EXTENSION_REGEX' | grep -E '\$FORMAT_REGEX'); do        \
        $CLANG_FORMAT -i \\\$f;                                                                                      \
        git add \\\$f;                                                                                               \
    done;                                                                                                            \
    git --amend --no-edit\"" base/$BASE_BRANCH 2>&1 || bot_error "Rebase failed, see the related [Action]($JOB_URL) for details"

# push back
git push --force-with-lease fork $LOCAL_BRANCH:$HEAD_BRANCH 2>&1 || bot_error "Cannot push rebased branch, are edits for maintainers allowed?"
