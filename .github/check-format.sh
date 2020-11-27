#!/bin/bash

cp .github/bot-pr-format-base.sh /tmp
source /tmp/bot-pr-format-base.sh

# check for changed files, replace newlines by \n
LIST_FILES=$(git diff --name-only | sed '$!s/$/\\n/' | tr -d '\n')

if [[ "$LIST_FILES" != "" ]]; then
  MESSAGE="The following files need to be formatted:\n"'```'"\n$LIST_FILES\n"'```'
  MESSAGE="$MESSAGE\nYou can find a formatting patch [here]($JOB_URL) or run "'`format!`'
  bot_error "$MESSAGE"
else
  bot_comment "No formatting necessary"
fi
