# frozen_string_literal: true

desc "Prepare a gem release"

flag :gems, "--gems=VAL"
flag :git_remote, "--git-remote=VAL", default: "origin"
flag :git_user_email, "--git-user-email=VAL"
flag :git_user_name, "--git-user-name=VAL"
flag :release_ref, "--release-ref=VAL"
flag :yes, "--yes", "-y"

include :exec, exit_on_nonzero_status: true
include :terminal, styled: true
include :fileutils

def run
  require "release_utils"
  require "release_prepare"

  cd context_directory
  utils = ReleaseUtils.new self

  set :release_ref, utils.current_branch if release_ref.to_s.empty?
  set :git_user_name, nil if git_user_name.to_s.empty?
  set :git_user_email, nil if git_user_email.to_s.empty?

  preparer = ReleasePrepare.new utils,
                                release_ref: release_ref,
                                git_remote: git_remote,
                                git_user_name: git_user_name,
                                git_user_email: git_user_email

  gem_list = gems.to_s.empty? ? utils.all_gems : gems.split(/[\s,]+/)
  instances = gem_list.map do |gem_info|
    gem_name, override_version = gem_info.split ":", 2
    preparer.instance gem_name, override_version: override_version
  end

  instances.each do |instance|
    unless yes
      if instance.last_version
        puts "Last #{instance.gem_name} version: #{instance.last_version}", :bold
      else
        puts "No previous #{instance.gem_name} version.", :bold
      end
      puts "New #{instance.gem_name} changelog:", :bold
      puts instance.full_changelog
      puts
      unless confirm "Create release PR? ", :bold, default: true
        logger.error "Release aborted"
        next
      end
    end
    instance.prepare
  end
end
