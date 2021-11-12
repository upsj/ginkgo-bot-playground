#!/bin/bash

pushd old
source .github/bot-pr-base.sh
popd

bot_delete_comments_matching "This PR changes the Ginkgo ABI"

abidiff build-old/lib/libginkgod.so build-new/lib/libginkgod.so &> abi.diff || bot_error "This PR changes the Ginkgo ABI:\n```\n$(head -n2 abi.diff)\n```\nFor details check the full ABI diff under **Artifacts** [here]($JOB_URL)"