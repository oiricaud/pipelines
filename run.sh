#!/usr/bin/env bash

printf "=====================================================================\n\n"
printf "========================= AUTOMATOR =================================\n\n"

# define variables
CONFIG=$@
branch=$(git rev-parse --abbrev-ref HEAD)
repo_full_name=$(git config --get remote.origin.url | sed 's/.*:\/\/github.com\///;s/.git$//')
token=$(git config --global github.token)

# commits latest changes and pushes them to the git repo
commit_push_latest() {
  git add .
  git commit -m "uploading pipelines"
  git push -u origin master
}

# runs subscripts in the ci/ directory
env_package_release() {
  echo "env_package_release..."
  cd ./ci
  env.sh
  package.sh
  release.sh
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
  echo "create_release..."
  read -p "Enter Release Version: " version
  read -p "Enter description of release " text
  echo "Create release $version for repo: $repo_full_name branch: $branch"
  curl --data "$(get_release_info)" "https://api.github.com/repos/$repo_full_name/releases?access_token=$token"
}

# method is responsible for uploading an asset to a release
upload_asset() {
  echo "uploading asset..."

  read -p "Enter tag to upload asset: " tag

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

  # Upload asset
  echo "Uploading asset... "

  # Construct url
  GH_ASSET="https://uploads.github.com/repos/$repo_full_name/releases/$id/assets?name=$(basename $filename)"

  curl "$GITHUB_OAUTH_BASIC" --data-binary @"$filename" -H "Authorization: token $github_api_token" -H "Content-Type: application/octet-stream" "$GH_ASSET"

}


# method is responsible for changing key/value pairs for the kabanero cr
update_kabanero_cr() {

  # get current kabanero custom resource from openshift and store it in a temp file
  oc get kabaneros kabanero -o json > ./json/temp.json

  # define variables
  name_of_pipeline="oscar-custom-pipelines"
  pipeline_to_update=\"${name_of_pipeline}\"
  new_url="https://github.com/oiricaud/pipelines/releases/download/v42.0/default-kabanero-pipelines.tar.gz"
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

# ask user input
while true; do

  printf '\360\237\246\204'
  read -p " Do you want to
    $('\n') 1) Add, commit and push your latest changes to github?
    $('\n') 2) Create a git release for your pipelines
    $('\n') 3) Upload an asset to a git release version
    $('\n') 4) Update the Kabanero CR with a release?
    $('\n') 5) Create manifests for pipelines?
    $('\n> ')" user_input

  if [ "$user_input" = 1 ]; then
    echo "commit and push changes"
    commit_push_latest

  elif [ "$user_input" = 2 ]; then
    echo "creating release"
    create_release

  elif [ "$user_input" = 3 ]; then
    echo "uploading asset"
    upload_asset

  elif [ "$user_input" = 4 ]; then
    echo "update kabanero cr"
    update_kabanero_cr

  elif [ "$user_input" = 4 ]; then
  echo "env_package_ release"
  env_package_release

  fi

done
