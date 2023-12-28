module GitHook
  class Updater
    GIT_BIN = Redmine::Configuration["scm_git_command"] || "git"

    attr_writer :logger

    def initialize(payload, params = {})
      @payload = payload
      @params = params
    end

    def update_repos
      project = find_project
      repositories = git_repositories(project)
      if repositories.empty?
        log_info("Project '#{project}' ('#{project.identifier}') has no repository")
        return
      end

      repositories.each do |repository|
        tg1 = Time.now
        # Fetch the changes from Git
        update_repository(repository)
        tg2 = Time.now

        tr1 = Time.now
        # Fetch the new changesets into Redmine
        repository.fetch_changesets
        tr2 = Time.now

        logger.info { "  GitHook: Redmine repository updated: #{repository.identifier} (Git: #{time_diff_milli(tg1, tg2)}ms, Redmine: #{time_diff_milli(tr1, tr2)}ms)" }
      end
    end

    def update_review_issue_by_GitHub_webhook
      logger.info { "GitHub is not supported yet." }
    end

    def update_review_issue_by_GitLab_webhook
      identifier = get_identifier
      setting = GitHookSetting.all.order(:id).select {|i| i.available? && identifier =~ Regexp.new(i.project_pattern)}.first
      unless setting.present?
        log_info("Available GitHookSetting does not exist for the project '#{identifier}'")
        return
      end

      if params[:event_type] == "note"
        update_review_issue_by_GitLab_comment(setting)
      elsif params[:event_type] == "merge_request"
        update_review_issue_by_GitLab_merge_request(setting)
      end
    end

    private

    attr_reader :params, :payload

    def log_info(msg)
      logger.info { "  GitHook: #{msg}" }
    end

    def fail_not_found(msg)
      fail(ActiveRecord::RecordNotFound, "  GitHook: #{msg}")
    end

    # Executes shell command. Returns true if the shell command exits with a
    # success status code.
    #
    # If directory is given the current directory will be changed to that
    # directory before executing command.
    def exec(command, directory)
      logger.debug { "  GitHook: Executing command: '#{command}'" }

      # Get a path to a temp file
      logfile = Tempfile.new("git_hook_exec")
      logfile.close

      full_command = "#{command} > #{logfile.path} 2>&1"
      success = if directory.present?
        Dir.chdir(directory) do
          system(full_command)
        end
      else
        system(full_command)
      end

      output_from_command = File.readlines(logfile.path)
      if success
        logger.debug { "  GitHook: Command output: #{output_from_command.inspect}" }
      else
        logger.error { "  GitHook: Command '#{command}' didn't exit properly. Full output: #{output_from_command.inspect}" }
      end

      return success
    ensure
      logfile.unlink if logfile && logfile.respond_to?(:unlink)
    end

    # Finds the Redmine project in the database based on the given project
    # identifier
    def find_project
      identifier = get_identifier
      project = Project.find_by_identifier(identifier.downcase)
      fail(
        ActiveRecord::RecordNotFound,
        "No project found with identifier '#{identifier}'"
      ) if project.nil?
      project
    end

    # Gets the project identifier from the querystring parameters and if that's
    # not supplied, assume the Git repository name is the same as the project
    # identifier.
    def get_identifier
      identifier = get_project_name
      fail(
        ActiveRecord::RecordNotFound,
        "Project identifier not specified"
      ) if identifier.nil?
      identifier.to_s
    end

    # Attempts to find the project name. It first looks in the params, then in
    # the payload if params[:project_id] isn't given.
    def get_project_name
      project_id = params[:project_id]
      name_from_repository = payload.fetch("repository", {}).fetch("name", nil)
      project_id || name_from_repository
    end

    def git_command(command)
      GIT_BIN + " #{command}"
    end

    def git_repositories(project)
      repositories = project.repositories.select do |repo|
        repo.is_a?(Repository::Git)
      end
      repositories || []
    end

    def logger
      @logger || NullLogger.new
    end

    def system(command)
      Kernel.system(command)
    end

    def time_diff_milli(start, finish)
      ((finish - start) * 1000.0).round(1)
    end

    # Fetches updates from the remote repository
    def update_repository(repository)
      command = git_command("fetch origin")
      fetch = exec(command, repository.url)
      return nil unless fetch

      command = git_command(
        "fetch --prune --prune-tags origin \"+refs/heads/*:refs/heads/*\""
      )
      exec(command, repository.url)
    end

    def update_review_issue_by_GitLab_comment(setting)
      unless params[:merge_request].present?
        log_info("Only comments on merge requests is supported.")
        return
      end

      reviewer = find_user(params[:user][:username], params[:user][:email])

      project = find_project
      parent = find_review_issue(project, "merge_request_url", params[:merge_request][:url], params[:merge_request][:description])
      unless parent.present?
        log_info("Linked review issue is not found. merge_request_url='#{params[:merge_request][:url]}'")
        return
      end
      if parent.closed?
        log_info("Linked review issue has been closed. '#{parent}'")
        return
      end

      child = Issue.where('project_id = ? AND description like ?',
        project.id, "%_discussion_id=#{params[:object_attributes][:discussion_id]}%").last
      view_on_git = create_link("View on Git", params[:object_attributes][:url])
      if child.present?
        child.description = child.description.gsub(/_blocking_discussions_resolved=.*,/,
          "_blocking_discussions_resolved=#{params[:merge_request][:blocking_discussions_resolved]},")
        child.description = child.description.gsub(/_type=.*,/, "_type=#{params[:object_attributes][:type]},")

        comment = "#{params[:object_attributes][:note]}"
        keyword_to_resolve = setting.keyword_to_resolve_discussion
        if comment.include?(keyword_to_resolve)
          comment = comment.gsub!(keyword_to_resolve, "").strip
          if comment.empty?
            comment = view_on_git
          else
            comment << "\n\n"
            comment << "---\n\n"
            comment << view_on_git
          end
          close_child(reviewer, setting.remark_issue_closed_status, child, comment)
          log_info("Redmine indicated issue closed. '#{child}'")
        else
          comment << "\n\n"
          comment << "---\n\n"
          comment << view_on_git
          child.init_journal(reviewer, comment)
          child.save
          child.reload
          log_info("Comment '#{params[:object_attributes][:note]}' added to '#{child}'.")
        end
      else
        if params[:merge_request][:state] != "opened"
          log_info("This merge request is not open so no issues can be added. '#{params[:merge_request][:url]}'")
          return
        end

        today = Time.zone.today
        description = "#{params[:object_attributes][:note]}"
        description << "\n\n"
        description << "---\n\n"
        description << "#{view_on_git} \n\n"
        description << "{{collapse(Please do not edit the followings.)\n"
        description << "_discussion_id=#{params[:object_attributes][:discussion_id]},\n"
        description << "_type=#{params[:object_attributes][:type]},\n"
        description << "_blocking_discussions_resolved=#{params[:merge_request][:blocking_discussions_resolved]},\n"
        description << "}} "
        subject = description.partition("\n")[0]
        child = Issue.new(
          :project_id => parent.project_id,
          :tracker_id => setting.remark_issue_tracker,
          :category_id => parent.category_id,
          :assigned_to_id => parent.assigned_to_id,
          :fixed_version_id => parent.fixed_version_id,
          :parent_issue_id => parent.id,
          :author_id => reviewer.id,
          :start_date => today,
          :due_date => today + 3.days,
          :subject => subject,
          :description => description
        )
        child.save
        child.reload
        log_info("Redmine review indicated issue added. '#{child}'")
      end
    end

    def update_review_issue_by_GitLab_merge_request(setting)
      action = params[:object_attributes][:action]
      if action != "merge" && action != "update"
        log_info("'#{action}' action is not supported.")
        return
      end

      reviewer = find_user(params[:user][:username], params[:user][:email])

      project = find_project
      parent = find_review_issue(project, "merge_request_url", params[:object_attributes][:url], params[:object_attributes][:description])
      unless parent.present?
        log_info("Linked review issue is not found. merge_request_url='#{params[:object_attributes][:url]}'")
        return
      end
      if parent.closed?
        log_info("Linked review issue has been closed. '#{parent}'")
        return
      end

      tracker_id = setting.remark_issue_tracker
      closed_id = setting.remark_issue_closed_status
      if action == "merge"
        children = parent.children.where('tracker_id = ? AND status_id != ? AND description like ?',
          tracker_id, closed_id, "%_blocking_discussions_resolved=%")
        close_children(reviewer, closed_id, children, "This issue was closed because the merge request was merged.")
      elsif action = "update"
        resolved = params[:object_attributes][:blocking_discussions_resolved]
        if resolved
          children = parent.children.where('tracker_id = ? AND status_id != ? AND (description like ? OR description like ?)',
            tracker_id, closed_id, "%_blocking_discussions_resolved=false%", "%_type=null%")
          close_children(reviewer, closed_id, children, "This issue was closed because all threads are resolved.")
        else
          log_info("Some threads has not been resolved.")
        end
      end
    end

    def find_user(username, email)
      reviewer = User.find_by_login(username)
      reviewer = User.find_by_mail(email) unless reviewer.present?
      unless reviewer.present?
        fail_not_found("Reviewer not found. username=#{username} or email=#{email}")
      end
      return reviewer
    end

    def find_review_issue(project, request_keyword, request_url, description)
      issues = Issue.where('project_id = ? AND description like ?',
        project.id, "%_#{request_keyword}=#{request_url}%")
      if issues.any?
        return issues.last
      else
        if m = description.match("refs #([0-9]+)")
          return Issue.find_by_id(m[1])
        end
      end
    end

    def create_link(header, url)
      if Setting.text_formatting == "textile"
        return "\"#{header}\":#{url} "
      elsif Setting.text_formatting == "markdown"
        return "[#{header}](#{url}) "
      else
        return url
      end
    end

    def close_child(reviewer, closed_id, child, comment)
      child.init_journal(reviewer, comment)
      child.status_id = closed_id
      child.save
      child.reload
    end

    def close_children(reviewer, closed_id, children, comment)
      if children.present? && children.any?
        comment << "\n\n"
        comment << "---\n\n"
        comment << "\"View on Git\":#{params[:object_attributes][:url]}"
        children.each do |child|
          close_child(reviewer, closed_id, child, comment)
        end
        log_info("Redmine indicated issue(s) closed. #{children.map { |child| "'#{child}'" }.join(', ')}")
      else
        log_info("No indicated issues that need to close.")
      end
    end

  end
end
