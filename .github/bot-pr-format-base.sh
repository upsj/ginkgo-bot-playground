#!/bin/bash

source .github/bot-pr-base.sh

git remote add fork "$HEAD_URL"
git fetch fork "$HEAD_BRANCH"

git config user.email "ginkgo.library@gmail.com"
git config user.name "ginkgo-bot"

# save scripts from develop
pushd dev_tools/scripts
cp format_header.sh update_ginkgo_header.sh /tmp
popd

# checkout current PR head
LOCAL_BRANCH=format-tmp-$HEAD_BRANCH
git checkout -b $LOCAL_BRANCH fork/$HEAD_BRANCH

# restore files from develop
cp /tmp/format_header.sh dev_tools/scripts/
cp /tmp/update_ginkgo_header.sh dev_tools/scripts/

# format files
CLANG_FORMAT=clang-format-8
dev_tools/scripts/update_ginkgo_header.sh
find benchmark core cuda hip include omp reference -type f \
    \( -name '*.cuh' -o -name '*.hpp' -o -name '*.hpp.in' \
    -o -name '*.cpp' -o -name '*.cu' -o -name '*.hpp.inc' \) \
    -exec dev_tools/scripts/format_header.sh -i "{}" \;
find common examples test_install -type f \
    \( -name '*.cuh' -o -name '*.hpp' -o -name '*.cpp' \
    -o -name '*.cu' -o -name '*.hpp.inc' \) \
    -exec "$CLANG_FORMAT" -i -style=file "{}" \;

# restore formatting scripts so they don't appear in the diff
git checkout -- dev_tools/scripts/*.sh
