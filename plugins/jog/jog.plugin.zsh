#/bin/zsh

MASTER="master"

_print_to_std_err() {
    echo $1 >&2
}

function _jog_check_env(){
 if ! [ -z $JIRA_USER ] && ! [ -z $JIRA_REST_API ] && ! [ -z $JIRA_BROWSE ] && ! [ -z $EPIC_FIELD ] && ! [ -z $RESOLUTION_DESCRIPTION_FIELD ] && ! [ -z $JAAS_SERVER ]; then
  return 0;
 else
  echo "not all required env variables are set, pls view the readme file for more info"
  return 1;
 fi
}

# ------------------------------------------------------------------------------

# make jira calls and return the json data
function _jira_get() {

 _jog_check_env

 if [ $? -eq 1 ]; then
  return -1
 fi

 if [ -z $1 ]; then
  _print_to_std_err "requires jira issue id or key"
  return -1
 fi
 
 _print_to_std_err "fetching jira issue $1"
 
 local json=$(curl -s -X GET -H "Authorization: Basic $JIRA_USER" $JIRA_REST_API/issue/$1)

 echo "$json"

  return 0
}

# ------------------------------------------------------------------------------

# parse json using jq and yield the property from json
# $1 = json
# $2 = property
function _jq() { 
 echo $1 | tr '\r\n' ' ' | jq -r ."$2"
}

# ------------------------------------------------------------------------------

# get jira issue details
function _jira_issue_details_cmd() {
    local json=$(_jira_get $1)

    _jira_issue_details $json $2
}

# ------------------------------------------------------------------------------

# get jira issue details
function _jira_issue_details() {
 
 local json="$1"

 if [ -z "$json" ]; then # see if the return is success
  return -1;
 fi

 # if there is error message from Jira print and return empty
 errorMessages="$(_jq $json errorMessages)"

 if ! [ -z $errorMessages ] && [ $errorMessages != "null" ]; then
  _print_to_std_err "Error(s) : $errorMessages"
  return -1
 fi

 local epic_key=$(_jq $json fields.$EPIC_FIELD)
 local epic_json="$(_jira_get $epic_key)"
 local epic="$(_jq $epic_json fields.summary)"

 local summary="$(_jq $json fields.summary)"
 local url="$(_jq $json self)"
 local key="$(_jq $json key)"
 local assignee="$(_jq $json fields.assignee.displayName)"
 local assignee_id="$(_jq $json fields.assignee.name)"
 local reporter="$(_jq $json fields.reporter.displayName)"
 local priority="$(_jq $json fields.priority.name)"
 local issue_type="$(_jq $json fields.issuetype.name)"
 local description="$(_jq $json fields.description)"
 local issue_status="$(_jq $json fields.status.name)" 
 local issue_icon="$(_jq $json fields.issuetype.iconUrl)"
 local status_color="$(_jq $json fields.status.statusCategory.colorName)"

 if [ -n "$2" ]; then
  echo "$summary \n" # dont add hash to signify as header, hub picks the first line as head

  echo "JIRA: [$key]($url) \n" 
  echo "Type          : $issue_type ![alt text]($issue_icon \"$issue_type\")"

  echo "\`\`\`console"
 else
  echo "Summary       : $summary"
 fi


 # print issue details
 
 echo "Assigned To   : $assignee ($assignee_id)"
 echo "Reporter      : $reporter"
 echo "Priority      : $priority"

 # wrap by 80 char length and dont break on space
 echo "Description   : $description" | fold -w 80 -s 

 if [ -n "$2" ]; then
  echo "Epic          : $epic"
  echo "Status        : $issue_status"
  echo "\`\`\`"
 else  
  echo "Epic          : $fg[blue]$epic$reset_color"
  echo "Status        : $fg[$status_color]$issue_status$reset_color"
 fi

  return 0
}

# ------------------------------------------------------------------------------

# add comments to a JIRA issue
function _jira_add_comments() {
  _jog_check_env

 if [ $? -eq 1 ]; then
  return -1
 fi

 if ! [ $# -eq 2 ]; then
  _print_to_std_err 'requires 1. JIRA issue key, 2. body for the comment'
  return -1
 fi

 if [ -z $2 ]; then
  _print_to_std_err 'no contents for JIRA comments'
  return -1
 fi

 comment="{\"body\": $2}"

 curl -s -X POST --data "$comment" -H "Content-Type: application/json" -H "Authorization: Basic $JIRA_USER" $JIRA_REST_API/issue/$1/comment >> /dev/null
 
 return $?
}

# ------------------------------------------------------------------------------

# parse jira comments and fetch details from it
# param 1: issue Key
# param 2: comment id
# param 3: issue summary
# param 4: md
function _jira_comment_details() {
 comment=$(_jira_get "$1/comment/$2")

 if [ -z "$comment" ]; then # see if the return is success
  _print_to_std_err "No comments found"
  return -1;
 fi

 # if there is error message from Jira print and return empty
 errorMessages="$(_jq $comment errorMessages)"

 if ! [ -z $errorMessages ] && [ $errorMessages != "null" ]; then
  _print_to_std_err "Error(s) : $errorMessages"
  return -1
 fi

 comment_author=$(_jq $comment author.displayName)
 comment_body=$(_jq $comment body)
 
 comment_author_id=$(_jq $comment author.name)

 if [ -n "$4" ]; then
  echo "Issue from Jira $1($3) - comment($2) \n" # dont add hash to signify as header, hub picks the first line as head

  echo "**JIRA Comment:** [$1]($JIRA_BROWSE/$1?focusedCommentId=$2&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-$2)\n" 
  echo -e "**Description  :** $comment_body" | fold -w 80 -s
  echo "**Author         :** $comment_author"
 else
  echo "Summary       :Issue from Jira $1 - comment \n"
  echo "JIRA Comment  : $1"
  echo -e "Description  : $comment_body" | fold -w 80 -s
  echo "Author         : $comment_author"
 fi 
}
# ------------------------------------------------------------------------------

function _git_issue_labels() {
 local json=$1

 if [ -z "$json" ]; then # see if the return is success
  return -1;
 fi

 local epic_key=$(_jq $json fields.$EPIC_FIELD)
 local key="$(_jq $json key)"
 local priority="$(_jq $json fields.priority.name)"
 local issue_type="$(_jq $json fields.issuetype.name)"

 local labels="$issue_type,$priority,$epic_key,$key"

 if [ "$(_jq $json '' | jq -r '.fields.labels|length')" -gt 0 ]; then
  labels="$labels,$(echo $json|_jq $json ''|jq -r '.fields.labels|join(",")')"
 fi

 echo "$labels"

 return 0
}

# ------------------------------------------------------------------------------

# git checkout branch
# param 1: jira issue key
# param 2: jira comment id (optional, only if you want to start a issue from a comment)
function _jog_checkout() {    

 if [ -z $1 ]; then
  echo 'checkout requires branch name(Jira issue key name)'
  return -1
 fi

#  _jog_hub_create_issue $1 $2 # create a equivaled github issue
 
#  if ! [ $? -eq 0 ]; then
#   return -1
#  fi 

 _jog_git_checkout $1 $2 # continue to checkout

  return $?
}

# ------------------------------------------------------------------------------
# param 1: jira issue key
# param 2: jira comment id (optional)
function _jog_git_checkout() {
  _jog_check_env

 if [ $? -eq 1 ]; then
  return -1
 fi

 # switch to master
 if [ $(echo "$(git_current_branch)") != $MASTER ]; then
  gco master
 fi

 # get latest from upstream master, so that we have latest code to work upon
 glum > /dev/null

 if ! [ $? -eq 0 ]; then # if couldnt pull from upstream
  _print_to_std_err 'could not pull from upstream, pls check remotes'
  return -1 # stop processing
 fi

 # check if branch already exists
 gb | grep $1

 if [ $? -eq 0 ]; then
  # if branch already exists, switch to that branch
  _print_to_std_err "branch $1 already found, checking out"
  gco $1

  if [ $? -eq 0 ] && ! [ -z $2 ]; then # create github issue should be created for jira comment
    _jog_hub_create_issue $1 $2
  fi
 else
  # create new branch and checkout
  gcb $1
  if [ $? -eq 0 ]; then
   _jog_hub_create_issue $1 $2 # create github issue
  fi
 fi

 return $?
}

# ------------------------------------------------------------------------------
# param 1: jira issue key
# param 2: jira comment id (optional)
function _jog_hub_create_issue(){

 local json=$(_jira_get $1)

 _print_to_std_err "Creating github issue for jira ticket $1 $2"

 #check if jira comments exists, its easy for developer to checkout a jira comment multiple times, this will create duplicate github issue
 local similar_github_issue=$(hub issue -f "%I %t%n" | grep "Issue from Jira .* - comment($2)" | awk '{print $1}')

  echo $similar_github_issue

 local jira_issue_browse_url=""
 
 if [ -z $similar_github_issue ]; then
    if [ -z $2 ]; then
     jira_issue_browse_url="$JIRA_BROWSE/$1"
     _jira_issue_details $json "md" > .issue.md # mk tmp md file of jira details
    else      
     jira_issue_browse_url="$JIRA_BROWSE/$1?focusedCommentId=$2&page=com.atlassian.jira.plugin.system.issuetabpanels%3Acomment-tabpanel#comment-$2"
    # mk tmp md file of jira comments
     _jira_comment_details $1 $2 $(_jq $json fields.summary) "md" > .issue.md
    fi
    
    local issue_labels=$(_git_issue_labels $json)

    local github_issue_url=$(echo $(hub issue create -F .issue.md -a "$assignee_id" -l "$issue_labels"))

    rm .issue.md # delete the temp file

    local issue_number=$(echo $github_issue_url | sed 's#.*/##')
    local body="\"*New @Github * [#$issue_number | $github_issue_url] has been created for the [discussion | $jira_issue_browse_url]\""

    # add github issue to jira comments
    _jira_add_comments $1 $body
 else
  # TODO: assign current user to github issue
 fi

 return $?

}

# ------------------------------------------------------------------------------

function _jog_commit() {
  _jog_check_env

 if [ $? -eq 1 ]; then
  return -1
 fi

 if [ $# -lt 2 ]; then
  echo "commit requires message and github issue number(s)"
  return -1
 fi

 local commit_message="$(for i in ${@:2}; do echo "#$i"; done)"

 commit_message=$(echo "$1\nFixes following issues\n$commit_message\n\n")
 
 git commit -m $commit_message

}

function _jog_pr() {
  _jog_check_env

 if [ $? -eq 1 ]; then
  return -1
 fi

 # this should give org/repo name
 local org_repo_name=$(grv get-url --all upstream | sed -e 's/.*:\(.*\).git.*/\1/')

 if ! [ $? -eq 0 ]; then
  echo "$org_repo_name"
  echo "check if remote upstream is added to git remote"
  return -1
 fi

 local branch_name=$(git_current_branch)

 glum # pull upstream master, so that if there is any conflict it can be fixed

 # find unpushed commits not in origin master and will be send as PR
 # we expect the #N (github issue number)
 local commits=$(git cherry -v upstream/master)

 local json=$(_jira_get $branch_name)

 if [ -z "$json" ]; then # see if the return is success
  return -1;
 fi

 local summary="$(_jq $json fields.summary)"
 local url="$(_jq $json self)"
 local key="$branch_name"
 local description="$(_jq $json fields.description)"
 
 echo -e "$key - $summary \r\n\r\n [JIRA Issue]($url) \r\n\r\n $(echo $description | fold -w 80 -s) \r\n\r\n Fixes: $(echo $commits | awk '{print $NF}' | uniq)" > .prdetail.md

 ggpush # push the branch to origin, before creating PR
 
 #create pull-request and assign the pr number to a variable
 local pr_number=0

 # create pr and return the url to the newly created pr
 local pr_url=$(hub pull-request -F .prdetail.md | grep -o 'https://.*')
 #  echo "pr url: $pr_url"
 
 # delete the temp md file
 rm .prdetail.md

 # fetch the PR number part from the returned url
 pr_number=$(echo $pr_url |  sed 's#.*/##')
 #  echo "pr Number: $pr_number"

 # pr number should be a integer, if not then its a message from hub pull request
 if ! [[ $pr_number =~ '^[0-9]+$' ]]; then
  _print_to_std_err "Unable to create pr $pr_url"
  return -1 # hub pr not successfull return
 fi

  # put the build status icon from jaas
 local ci_status_icon_url="$JAAS_SERVER/buildStatus/icon?job=$org_repo_name/$pr_number&style=flat-square"
 

 # TODO: try to add the PR status icon for jira comments
 local jira_comment_body="\"*New PR Submitted* \n\nCI Status of PR !$ci_status_icon_url! \n[Link to PR | $pr_url]\""

 _print_to_std_err "adding jira comments"

 local jira_peer_review_id=$(curl -s -H "Authorization: Basic $JIRA_USER" $JIRA_REST_API/issue/$key/transitions | jq -r '.transitions[] | select(.name=="Peer Review")|.id')

 _jira_add_comments $key $jira_comment_body

 if ! [ -z jira_peer_review_id ]; then
  _print_to_std_err "Moving $branch_name to Peer Review"
  # move jira issue to Peer Review
  local jira_body="{\"update\":{\"comment\": [{\"add\":{\"body\":$jira_comment_body}}]},\"transition\":{\"id\": \"$jira_peer_review_id\"}}"

#   echo $jira_body

  curl -s -X POST --data "$jira_body" -H "Content-Type: application/json" -H "Authorization: Basic $JIRA_USER" $JIRA_REST_API/issue/$branch_name/transition >> /dev/null
 fi
}

# ------------------------------------------------------------------------------

 alias j="_jira_get"
 alias jd="_jira_issue_details_cmd"

 alias jco="_jog_checkout"
 alias jc="_jog_commit"
 alias jpr="_jog_pr"

