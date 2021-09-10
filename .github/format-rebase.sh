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

bot_delete_comments_matching "Error: Rebase failed"

# do the formatting rebase
git rebase --exec "bash -c \"                                                                                        \
    for f in \\\$(git diff --name-only --cached | grep -E '\$EXTENSION_REGEX' | grep -E '\$FORMAT_HEADER_REGEX'); do \
        /tmp/format_header.sh \\\$f;                                                                                 \
        git add \\\$f;                                                                                               \
    done;                                                                                                            \
    for f in \\\$(git diff --name-only --cached | grep -E '\$EXTENSION_REGEX' | grep -E '\$FORMAT_REGEX'); do        \
        $CLANG_FORMAT -i \\\$f;                                                                                      \
        git add \\\$f;                                                                                               \
    done\"" base/$BASE_BRANCH 2>&1 || bot_error "Rebase failed, see the related [Action]($JOB_URL) for details"
exit 1
# push back
git push --force-with-lease fork $LOCAL_BRANCH:$HEAD_BRANCH 2>&1 || bot_error "Cannot push rebased branch, are edits for maintainers allowed?"
