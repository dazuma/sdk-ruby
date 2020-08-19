# frozen_string_literal: true

desc "Job that marks a release PR as aborted"

flag :event_path, "--event-path=VAL"

include :exec, exit_on_nonzero_status: true
include :fileutils
include :terminal, styled: true

def run
  require "release_utils"

  cd context_directory
  utils = ReleaseUtils.new self

  pr = ::JSON.parse(::File.read(event_path))["pull_request"]
  pr_number = pr["number"]

  if pr["merged_at"]
    logger.info "PR #{pr_number} is merged. Ignoring."
    return
  end
  if pr["labels"].all? { |label_info| label_info["name"] != utils.release_pending_label }
    logger.info "PR #{pr_number} does not have the pending label. Ignoring."
    return
  end

  logger.info "Updating release PR #{pr_number} to mark it as aborted."
  utils.update_release_pr pr_number,
                          label:   utils.release_aborted_label,
                          message: "Release PR closed without merging.",
                          cur_pr:  pr
  logger.info "Done."
end
