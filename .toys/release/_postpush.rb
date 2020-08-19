# frozen_string_literal: true

desc "Post-push job that runs on merge of a release PR"

flag :ci_result, "--ci-result=VAL", default: "unknown"
flag :enable_releases, "--enable-releases[=VAL]"
flag :gh_pages_dir, "--gh-pages-dir=VAL"
flag :git_remote, "--git-remote=VAL", default: "origin"
flag :git_user_email, "--git-user-email=VAL"
flag :git_user_name, "--git-user-name=VAL"
flag :github_sha, "--github-sha=VAL"
flag :rubygems_api_key, "--rubygems-api-key=VAL"

include :exec, exit_on_nonzero_status: true
include :fileutils
include :terminal, styled: true

def run
  require "release_utils"
  require "release_perform"

  cd context_directory
  utils = ReleaseUtils.new self

  [:gh_pages_dir, :git_user_email, :git_user_name, :rubygems_api_key].each do |key|
    set key, nil if get(key).to_s.empty?
  end
  set :github_sha, utils.current_sha if github_sha.to_s.empty?

  pr = utils.find_release_prs merge_sha: github_sha
  if pr
    logger.info "This appears to be a merge of release PR #{pr['number']}."
    utils.on_error { |content| report_release_error pr, content, utils }
    gem_name = pr["head"]["ref"].sub("release/", "")
    gem_version = utils.current_library_version gem_name
    logger.info "The release is for #{gem_name} #{gem_version}."
    unless ci_result == "success"
      error "Release of #{gem_name} #{gem_version} failed because the CI result was #{ci_result}."
    end
    perform_release gem_name, gem_version, pr, utils
    utils.clear_error_proc
    mark_release_pr_as_completed gem_name, gem_version, pr, utils
  else
    logger.info "This was not a merge of a release PR."
    update_open_release_prs utils
    error "Failing post-push because the CI result was #{ci_result}." unless ci_result == "success"
  end
end

def perform_release gem_name, gem_version, pr, utils
  logger.info "CI passed for the merge."
  dry_run = /^t/i =~ enable_releases.to_s ? false : true
  docs_builder_tool = utils.gem_info gem_name, "docs_builder_tool"
  docs_builder = docs_builder_tool ? proc { exec_separate_tool Array(docs_builder_tool) } : nil
  performer = ReleasePerform.new utils,
                                 release_sha: github_sha,
                                 rubygems_api_key: rubygems_api_key,
                                 git_remote: git_remote,
                                 git_user_name: git_user_name,
                                 git_user_email: git_user_email,
                                 gh_pages_dir: gh_pages_dir,
                                 docs_builder: docs_builder,
                                 dry_run: dry_run
  performer.instance(gem_name, gem_version).perform
end

def mark_release_pr_as_completed gem_name, gem_version, pr, utils
  pr_number = pr["number"]
  logger.info "Updating release PR ##{pr_number} ..."
  message = "Released of #{gem_name} #{gem_version} complete!"
  utils.update_release_pr pr_number,
                          label: utils.release_complete_label,
                          message: message,
                          cur_pr: pr
  logger.info "Updated release PR."
end

def report_release_error pr, content, utils
  pr_number = pr["number"]
  logger.info "Updating the release PR ##{pr_number} to report an error ..."
  utils.update_release_pr pr_number,
                          label: utils.release_error_label,
                          message: content,
                          cur_pr: pr
  logger.info "Opening a new issue to report the failure ..."
  body = <<~STR
    Release PR: ##{pr_number}
    Commit: https://github.com/#{utils.repo_path}/commit/#{github_sha}
    Error message:
    #{content}
  STR
  response = capture ["gh", "issue", "create", "--repo", utils.repo_path,
                      "--title", "Release PR ##{pr_number} failed with an error.",
                      "--body", body]
  issue_number = ::JSON.parse(response)["number"]
  logger.info "Issue #{issue_number} opened."
end

def update_open_release_prs utils
  logger.info "Searching for open release PRs ..."
  prs = utils.find_release_prs
  if prs.empty?
    logger.info "No existing release PRs to update."
    return
  end
  commit_message = capture ["git", "log", "-1", "--pretty=%B"]
  pr_message = <<~STR
    WARNING: An additional commit was added while this release PR was open.
    You may need to add to the changelog, or close this PR and prepare a new one.

    Commit link: https://github.com/#{utils.repo_path}/commit/#{github_sha}

    Message:
    #{commit_message}
  STR
  prs.each do |pr|
    pr_number = pr["number"]
    logger.info "Updating PR #{pr_number} ..."
    utils.update_release_pr pr_number, message: pr_message, cur_pr: pr
  end
  logger.info "Finished updating existing release PRs."
end
