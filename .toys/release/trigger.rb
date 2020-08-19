# frozen_string_literal: true

desc "Trigger a release of cloud_events"

include :exec, exit_on_nonzero_status: true
include :terminal
include :fileutils
include "release-tools"

required_arg :gem_name
required_arg :version

flag :git_remote, "--git-remote=VAL", default: "origin"
flag :yes, "--yes", "-y"

def run
  cd context_directory

  puts "Running prechecks...", :bold
  verify_git_clean
  verify_library_version gem_name, version
  changelog_entry = verify_changelog_content gem_name, version
  verify_github_checks

  puts "Found changelog entry:", :bold
  puts changelog_entry
  if !yes && !confirm("Release #{gem_name} #{version}? ", :bold, default: true)
    error "Release aborted"
  end

  tag = "#{gem_name}/v#{version}"
  exec ["git", "tag", tag]
  exec ["git", "push", git_remote, tag]
  puts "SUCCESS: Pushed tag #{tag}", :green, :bold
end
