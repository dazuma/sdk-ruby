# frozen_string_literal: true

desc "Job that marks a release PR as aborted"

flag :event_path, "--event-path=VAL", default: ::ENV["GITHUB_EVENT_PATH"]

include :exec, exit_on_nonzero_status: true
include :fileutils
include :terminal, styled: true
include "release-tools"

def run
  cd context_directory
  verify_repo_identity git_remote: git_remote

  event_data = ::JSON.parse(::File.read(event_path))
  pr = event_data["pull_request"]
  pr_number = pr["number"]

  if pr["merged_at"]
    logger.info "PR #{pr_number} is merged. Ignoring."
    return
  end
  if pr["labels"].all? { |label_info| label_info["name"] != release_pending_label }
    logger.info "PR #{pr_number} does not have the #{release_pending_label.inspect} label. Ignoring."
    return
  end

  logger.info "PR #{pr_number} has the #{release_pending_label.inspect} label."
  logger.info "Updating release PR #{pr_number}."
  update_release_pr repo_path, pr_number,
                    label:   release_abort_label,
                    message: "Release PR closed without merging.",
                    cur_pr:  pr
  logger.info "Done."
end
