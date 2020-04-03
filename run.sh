#!/usr/bin/env bash

printf "========== RUN Release ==========\n\n"

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
  # oc get kabaneros kabanero -o yaml > tmp/kabanero.yaml

  echo $(cat temp.json | jq .spec.stacks.pipelines data.json) > temp.json

  name_of_pipeline="oscar-custom-pipelines"
  pipeline_to_update=\"${name_of_pipeline}\"
  # Iterate through all pipelines in stack and find the id that matches the same repo name
  num_of_pipelines=$(jq '.spec.stacks.pipelines | length' data.json)
  pipeline_index=0
  for ((n=0;n<num_of_pipelines;n++));
    do
      get_id=$(jq '.spec.stacks.pipelines | .['$n'].id' data.json)
      echo "----> pipeline:" "$get_id"
      if [ "$get_id" = $pipeline_to_update ]; then
        echo "found pipeline!"
        pipeline_index=$n;
      fi
  done
  printf $pipeline_index

  new_url="www.test.com"
  new_sha="123"

  jq '.spec.stacks.pipelines | .['$pipeline_index'].https.url = '\"${new_url}\"' | .['$pipeline_index'].sha256 = '\"${new_sha}\"' ' data.json | json_pp > kabanero.json

  temp=$(cat ./kabanero.json)

  echo $temp

  jq_get_pipelines=$(jq '.spec.stacks.pipelines='"${temp}"'' data.json)
  echo $jq_get_pipelines | json_pp > kabanero.json
  
  oc apply -f kabanero.json
}
# ask user input
while true; do

  printf '\360\237\246\204'
  read -p " Do you want to
    $(echo $'\n') 1) Create Release for your pipelines (when you want to push your pipelines to openshift)
    $(echo $'\n') 2) Upload Asset to a release (kabanero needs a place to call
    $(echo $'\n') 3) Add, commit and push your latest changes to github?
    $(echo $'\n') 4) Update the Kabanero CR with a release?
    $(echo $'\n> ')" user_input

  if [ "$user_input" = 1 ]; then
    echo "creating release"
    create_release

  elif [ "$user_input" = 2 ]; then
    echo "uploading asset"
    upload_asset

  elif [ "$user_input" = 3 ]; then
    echo "commit and push changes"
    commit_push_latest

  elif [ "$user_input" = 4 ]; then
    echo "update kabanero cr"
    update_kabanero_cr
  fi

done
