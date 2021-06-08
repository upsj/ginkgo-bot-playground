#!/bin/bash

set -e

git clone "https://${GITHUB_ACTOR}:${GITHUB_TOKEN}@github.com/upsj/CudaArchitectureSelector"

git config --global user.email "ginkgo.library@gmail.com"
git config --global user.name "ginkgo-bot"

GKO_PATH=third_party/CudaArchitectureSelector/CudaArchitectureSelector.cmake
CAS_PATH=CudaArchitectureSelector/CudaArchitectureSelector.cmake

if [[ $(diff "$GKO_PATH" "$CAS_PATH") ]]
then
    cp "$GKO_PATH" "$CAS_PATH"
    GIT_SHA=$(git rev-parse HEAD)
    cd CudaArchitectureSelector
    git add CudaArchitectureSelector.cmake
    git commit -m "Sync with https://github.com/upsj/ginkgo-bot-playground/commit/$GIT_SHA"
    git push
fi
