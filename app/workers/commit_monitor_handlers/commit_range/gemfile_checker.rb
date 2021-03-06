module CommitMonitorHandlers
  module CommitRange
    class GemfileChecker
      include Sidekiq::Worker
      sidekiq_options :queue => :miq_bot

      LABEL_NAME = "gem changes".freeze

      def self.handled_branch_modes
        [:pr]
      end

      attr_reader :branch, :commits, :github, :pr

      def perform(branch_id, _new_commits)
        @branch = CommitMonitorBranch.where(:id => branch_id).first

        if @branch.nil?
          logger.info("(##{__method__}) Branch #{branch_id} no longer exists.  Skipping.")
          return
        end

        unless @branch.enabled_for?(:gemfile_checker)
          logger.info("(##{__method__}) #{@branch.repo.fq_name} has not been enabled.  Skipping.")
          return
        end

        @pr      = @branch.pr_number
        @commits = @branch.commits_list

        files = diff_details_for_branch.keys
        return unless files.any? { |f| File.basename(f) == "Gemfile" }

        process_branch
      end

      private

      def diff_details_for_branch
        MiqToolsServices::MiniGit.call(branch.repo.path) do |git|
          git.diff_details(commits.first, commits.last)
        end
      end

      def tag
        "<gemfile_checker />"
      end

      def gemfile_comment
        contacts = Settings.gemfile_checker.pr_contacts.join(" ")
        where    = "#{'commit'.pluralize(commits.length)} #{commit_range}"

        message  = "#{tag}Gemfile changes detected in #{where}."
        message << " /cc #{contacts}" unless contacts.blank?
        message
      end

      def commit_range
        [
          branch.commit_uri_to(commits.first),
          branch.commit_uri_to(commits.last),
        ].uniq.join(" .. ")
      end

      def process_branch
        send("process_#{branch.pull_request? ? "pr" : "regular"}_branch")
      end

      def process_pr_branch
        logger.info("(##{__method__}) Updating pull request #{pr} with Gemfile comment.")

        branch.repo.with_github_service do |github|
          @github = github
          replace_gemfile_comments
          add_pr_label
        end
      end

      def replace_gemfile_comments
        github.replace_issue_comments(pr, gemfile_comment) do |old_comment|
          gemfile_comment?(old_comment)
        end
      end

      def add_pr_label
        logger.info("(##{__method__}) PR: #{pr}, Adding label: #{LABEL_NAME.inspect}")
        github.add_issue_labels(pr, LABEL_NAME)
      end

      def gemfile_comment?(comment)
        comment.body.start_with?(tag)
      end

      def process_regular_branch
        # TODO: Support regular branches with EmailService once we can send email.
      end
    end
  end
end
