# frozen_string_literal: true

desc "Perform post-push release tasks"

long_desc \
  "This tool can be called by a GitHub Actions workflow after a commit is" \
    " pushed to the main branch. It triggers a release if applicable, or" \
    " updates existing release pull requests. Generally, this tool should" \
    " not be invoked manually."

required_arg :ci_result

include :exec, exit_on_nonzero_status: true
include :fileutils
include :terminal, styled: true

def run
  require "release_utils"

  cd context_directory
  utils = ReleaseUtils.new self

  pr_info = utils.find_release_prs merge_sha: utils.current_sha
  if pr_info
    logger.info "This appears to be a merge of release PR #{pr_info['number']}."
    handle_release_pr pr_info, utils
  else
    logger.info "This was not a merge of a release PR."
    update_open_release_prs utils
    unless ci_result == "success"
      error "Exiting with an error code because the CI result was #{ci_result}."
    end
  end
end

def handle_release_pr pr_info, utils
  gem_name = pr_info["head"]["ref"].sub "release/", ""
  gem_version = utils.current_library_version gem_name
  logger.info "The release is for #{gem_name} #{gem_version}."
  unless ci_result == "success"
    msg = "Release of #{gem_name} #{gem_version} failed because the CI result was #{ci_result}."
    utils.report_release_error pr_info, msg, utils
    utils.error msg
  end
  path = "repos/#{utils.repo_path}/actions/workflows/#{utils.perform_workflow_name}/dispatches"
  inputs = { gem: gem_name, version: gem_version, flags: "--skip-checks --yes" }
  body = ::JSON.dump ref: utils.current_sha, inputs: inputs
  utils.exec ["gh", "api", path, "--input", "-", "-H", "Accept: application/vnd.github.v3+json"],
             in: [:string, body], out: :null
end

def update_open_release_prs utils
  logger.info "Searching for open release PRs ..."
  pulls = utils.find_release_prs
  if pulls.empty?
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
  pulls.each do |pull|
    pr_number = pullpr["number"]
    logger.info "Updating PR #{pr_number} ..."
    utils.update_release_pr pr_number, message: pr_message, cur_pr: pull
  end
  logger.info "Finished updating existing release PRs."
end
