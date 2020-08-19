# frozen_string_literal: true

desc "Post-push job that runs on merge of a release PR"

flag :repo, "--repo=VAL", default: ::ENV["GITHUB_REPOSITORY"]
flag :sha, "--sha=VAL", default: ::ENV["GITHUB_SHA"]
flag :git_remote, "--git-remote=VAL", default: "origin"
flag :result, "--result=VAL", default: "unknown"

include :exec, exit_on_nonzero_status: true
include :fileutils
include :terminal, styled: true
include "release-tools"

def run
  cd context_directory
  pr = find_release_prs repo, merge_sha: sha
  if pr
    pr_number = pr["number"]
    gem_name = pr["head"]["ref"].sub("release/", "")
    logger.info "This appears to be a merge of release PR #{pr_number} for #{gem_name}."
    if result == "success"
      trigger_release pr_number, gem_name, pr
    else
      report_trigger_aborted pr_number, gem_name, pr
    end
  else
    logger.info "This was not a merge of a release PR."
    update_open_release_prs
  end
  logger.info "Done."
  error "CI failed, so failing post-push." unless result == "success"
end

def trigger_release pr_number, gem_name, pr
  logger.info "CI passed for the merge."
  version = current_library_version gem_name
  verify_changelog_content gem_name, version
  tag = "#{gem_name}/v#{version}"
  logger.info "Tagging #{tag} ..."
  exec ["git", "tag", tag]
  exec ["git", "push", git_remote, tag]
  logger.info "Updating PR to report trigger success ..."
  update_release_pr repo, pr_number,
                    label:   release_triggered_label,
                    message: "Triggered release of #{gem_name} #{version}.",
                    cur_pr: pr
end

def report_trigger_aborted pr_number, gem_name, pr
  logger.info "CI failed for the merge."
  logger.info "Updating the release PR to report the error ..."
  update_release_pr repo, pr_number,
                    label:   release_error_label,
                    message: "CI failed on merge. Did not trigger #{gem_name} release.",
                    cur_pr: pr
  logger.info "Opening a new issue to report the failure ..."
  body = <<~STR
    Release of: #{gem_name} #{current_library_version gem_name}
    Release PR: ##{pr_number}
    Commit: https://github.com/#{repo}/commit/#{sha}
  STR
  exec ["gh", "issue", "create", "--repo", repo,
        "--title", "Release PR ##{pr_number} failed CI.",
        "--body", body]
end

def update_open_release_prs
  commit_message = capture ["git", "log", "-1", "--pretty=%B"]
  pr_message = <<~STR
    WARNING: An additional commit was added while this release PR was open.
    You may need to add to the changelog, or close this PR and prepare a new one.

    Commit link: https://github.com/#{repo}/commit/#{sha}

    Message:
    #{commit_message}
  STR
  logger.info "Searching for open release PRs..."
  prs = find_release_prs repo
  prs.each do |pr|
    pr_number = pr["number"]
    logger.info "Updating PR #{pr_number} ..."
    update_release_pr repo, pr_number, message: pr_message, cur_pr: pr
  end
end
