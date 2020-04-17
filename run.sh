#!/usr/bin/env bash

# define variables
CONFIG=$@
branch=$(git rev-parse --abbrev-ref HEAD)
repo_full_name=$(git config --get remote.origin.url | sed 's/.*:\/\/github.com\///;s/.git$//')
token=$(git config --global github.token)

# commits latest changes and pushes them to the git repo
commit_push_latest() {
  git add .
  git reset ./ci/env.sh
  git commit -m "uploading pipelines"
  git push -u origin master
}

# runs subscripts in the ci/ directory
env_package_release() {
  pwd
  cd ci
  ./env.sh
  ./package.sh
  ./release.sh
  cd ..
}

# gets the release information that gets uploaded to github
get_release_info() {
  {
    cat <<EOF
  {
    "tag_name": "$version",
    "target_commitish": "$branch",
    "name": "$version",
    "body": "$text",
    "draft": false,
    "prerelease": false
  }
EOF
  }
}

# method is responsible for creating a release
create_release() {
  read -p "Enter Release Version i.e v1.0 : " version
  read -p "Enter description of release " text
  echo "Create release $version for repo: $repo_full_name branch: $branch"
  curl --data "$(get_release_info)" "https://api.github.com/repos/$repo_full_name/releases?access_token=$token"
}

# method is responsible for uploading an asset to a release
upload_asset() {
  read -p "Upload asset to what version? i.e v1.0 : " tag

  filename=./ci/assets/default-kabanero-pipelines.tar.gz
  github_api_token=$(git config --global github.token)
  repo_full_name=$(git config --get remote.origin.url | sed 's/.*:\/\/github.com\///;s/.git$//')

  set -e xargs="$(which gxargs || which xargs)"

  # Validate settings.
  [ "$TRACE" ] && set -x

  for line in $CONFIG; do
    eval "$line"
  done

  # Define variables.
  GH_API="https://api.github.com"
  GH_REPO="$GH_API/repos/$repo_full_name"
  GH_TAGS="$GH_REPO/releases/tags/$tag"
  AUTH="Authorization: token $github_api_token"

  if [[ "$tag" == 'LATEST' ]]; then
    GH_TAGS="$GH_REPO/releases/latest"
  fi

  # Validate token.
  curl -o /dev/null -sH "$AUTH" $GH_REPO || {
    echo "Error: Invalid repo, token or network issue!"
    exit 1
  }

  # Read asset tags.
  response=$(curl -sH "$AUTH" $GH_TAGS)

  # Get ID of the asset based on given filename.
  eval $(echo "$response" | grep -m 1 "id.:" | grep -w id | tr : = | tr -cd '[[:alnum:]]=')
  [ "$id" ] || {
    echo "Error: Failed to get release id for tag: $tag"
    echo "$response" | awk 'length($0)<100' >&2
    exit 1
  }

  # Construct url
  GH_ASSET="https://uploads.github.com/repos/$repo_full_name/releases/$id/assets?name=$(basename $filename)"

  curl "$GITHUB_OAUTH_BASIC" --data-binary @"$filename" -H "Authorization: token $github_api_token" -H "Content-Type: application/octet-stream" "$GH_ASSET"
}


# method is responsible for changing key/value pairs for the kabanero cr
update_kabanero_cr() {

  oc project kabanero
  # get current kabanero custom resource from openshift and store it in a temp file
  oc get kabaneros kabanero -o json > ./json/temp.json

  read -p "Enter name of pipeline to update " name_of_pipeline
  read -p "Enter release version to use on this pipeline " release_version

  # define variables
  pipeline_to_update=\"${name_of_pipeline}\"
  new_url="https://github.com/oiricaud/pipelines/releases/download/$release_version/default-kabanero-pipelines.tar.gz"
  get_sha=$(shasum -a 256 ./ci/assets/default-kabanero-pipelines.tar.gz | grep -Eo '^[^ ]+' )

  # add double quotes to the sha256
  new_sha=\"${get_sha}\"

  # Iterate through all pipelines in stack and find the id that matches the same repo name
  num_of_pipelines=$(jq '.spec.stacks.pipelines | length' ./json/temp.json)
  pipeline_index=0
  for ((n=0;n<num_of_pipelines;n++));
    do
      get_id=$(jq '.spec.stacks.pipelines | .['$n'].id' ./json/temp.json)
      echo "----> pipeline:" "$get_id"
      if [ "$get_id" = $pipeline_to_update ]; then
        echo "found pipeline!"
        pipeline_index=$n;
      fi
  done
  printf $pipeline_index

  # update values for keys url and sha256 and store it in a new kaberno.json file
  jq '.spec.stacks.pipelines | .['$pipeline_index'].https.url = '\"${new_url}\"' | .['$pipeline_index'].sha256 = '$new_sha'' ./json/temp.json | json_pp > ./json/kabanero.json

  # store everything inside the pipelines object
  jq_get_pipelines=$(jq '.spec.stacks.pipelines='"$(cat ./json/kabanero.json)"'' ./json/temp.json)

  # slap the pipelines and replace them from the kabanero.json file
  echo $jq_get_pipelines | json_pp > ./json/kabanero.json

  # update the changes to the kabanero custom resource
  oc apply -f ./json/kabanero.json

  # print the new results
  oc get kabaneros kabanero -o yaml
}


add_pipeline_kabanero_cr() {
  oc project kabanero

  oc get kabaneros kabanero -o json > ./json/temp.json

  read -p "Enter label for pipeline [i.e mcm-pipelines] " name_of_pipeline
  read -p "Where are the pipelines being hosted? [i.e www.github.com/org/repo-pipelines/kabanero.tar.gz] " host_url
  read -p "Enter name of tar file " tar_file_name

  wget $host_url

  get_sha=$(shasum -a 256 ./$tar_file_name | grep -Eo '^[^ ]+' )

  echo $get_sha

  # add double quotes to the sha256
  new_sha=\"${get_sha}\"
  generate_sha=
  jq '.https.url="'$host_url'" | .id="'$name_of_pipeline'" | .sha256="'$get_sha'"'  ./json/add_pipeline_template.json > ./json/add_pipeline_modified_template.json

  cat ./json/add_pipeline_modified_template.json

  rm ./default-kabanero-pipelines.tar.gz

  result=$(jq '.spec.stacks.pipelines[1]='"$(cat ./json/add_pipeline_modified_template.json)"'' ./json/kabanero.json)

  echo $result | json_pp > ./json/kabanero-2.json

}

printf "===========================================================================\n\n"
printf "======================== AUTOMATOR SCRIPT =================================\n\n"
printf "===========================================================================\n\n"

# ask user input
while true; do

  printf '\360\237\246\204'
  read -p " Do you want to
    1) Set up environment, containerzied pipelines and release them to a registry?
    2) Add, commit and push your latest changes to github?
    3) Create a git release for your pipelines?
    4) Upload an asset to a git release version?
    5) Update the Kabanero CR custom resource with a release?
    6) Add a stable pipeline release version to the Kabanero custom resource?
    enter a number > " user_input

  if [ "$user_input" = 1 ]; then
    printf "**************************************************************************\n\n"
    printf "**************** BEGIN SETTING UP ENV, PACKAGE AND RELEASE ***************\n\n"
    printf "**************************************************************************\n\n"

    env_package_release

    printf "\n*************************************************************************\n\n"
    printf "**************** FINISHED SETTING UP ENV, PACKAGE AND RELEASE *************\n\n"
    printf "**************************************************************************\n\n"

  elif [ "$user_input" = 2 ]; then
    printf "**************************************************************************\n\n"
    printf "================ BEGIN GIT ADD, COMMIT AND PUSH ===========================\n\n"
    printf "**************************************************************************\n\n"

    commit_push_latest

    printf "**************************************************************************\n\n"
    printf "================ FINISHED GIT ADD, COMMIT AND PUSH ========================\n\n"
    printf "**************************************************************************\n\n"

  elif [ "$user_input" = 3 ]; then
    printf "**************************************************************************\n\n"
    printf "================ BEGIN CREATING RELEASE ===================================\n\n"
    printf "**************************************************************************\n\n"

    create_release

    printf "**************************************************************************\n\n"
    printf "================ FINISHED CREATING RELEASE ================================\n\n"
    printf "**************************************************************************\n\n"

  elif [ "$user_input" = 4 ]; then
    printf "**************************************************************************\n\n"
    printf "================ BEGIN UPLOADING ASSET ====================================\n\n"
    printf "**************************************************************************\n\n"

    upload_asset

    printf "**************************************************************************\n\n"
    printf "================ FINISHED UPLOADING ASSET =================================\n\n"
    printf "**************************************************************************\n\n"

  elif [ "$user_input" = 5 ]; then
    printf "**************************************************************************\n\n"
    printf "================ BEGIN UPDATING KABANERO CUSTOM RESOURCE ==================\n\n"
    printf "**************************************************************************\n\n"

    update_kabanero_cr

    printf "**************************************************************************\n\n"
    printf "================ FINISHED UPDATING KABANERO CUSTOM RESOURCE ===============\n\n"
    printf "**************************************************************************\n\n"

  elif [ "$user_input" = 6 ]; then
    printf "**************************************************************************\n\n"
    printf "========== BEGIN ADDING PIPELINE TO KABANERO CUSTOM RESOURCE ==============\n\n"
    printf "**************************************************************************\n\n"

    add_pipeline_kabanero_cr

    printf "**************************************************************************\n\n"
    printf "======== FINISHED ADDING PIPELINE TO KABANERO CUSTOM RESOURCE ============\n\n"
    printf "**************************************************************************\n\n"

  fi

done
