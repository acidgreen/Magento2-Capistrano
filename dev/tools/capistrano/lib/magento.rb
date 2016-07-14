#ssh_options[:forward_agent] = true
default_run_options[:pty] = true  # Must be set for the password prompt 

set :composer_bin, "composer"

# from git to work
set :application, "{put_application_name}"
set :repository,  "git@bitbucket.org:acidgreen/{project}.git"
# Or: `accurev`, `bzr`, `cvs`, `darcs`, `git`, `mercurial`, `perforce`, `subversion` or `none`
set :scm, :git
set :use_sudo, false
set :group_writable, true

set :keep_releases, 2
set :stage_dir, "dev/tools/capistrano/config/deploy"

set :app_symlinks, ["/pub/media", "/var"]
set :app_shared_dirs, ["/app/etc/", "/pub/media", "/var"]
set :app_shared_files, ["/app/etc/config.php","/app/etc/env.php"]


set :stages, %w(dev staging production)
set :default_stage, "dev"

load 'config/deploy'
require 'capistrano/ext/multistage'

def remote_file_exists?(full_path)
  'true' ==  capture("if [ -e #{full_path} ]; then echo 'true'; fi").strip
end


# we will ask which tag to deploy; default = latest
# http://nathanhoad.net/deploy-from-a-git-tag-with-capistrano
set :branch do
    Capistrano::CLI.ui.say "    Retrieving available branches and tags...\n\n"
    branches, tags = [], []
    `git ls-remote #{repository}`.split("\n").each { |branch_tag|
        tags.push branch_tag if branch_tag.include? "refs/tags/"
        branches.push branch_tag if branch_tag.include? "refs/heads/"
    }

    if not tags.empty? then
        Capistrano::CLI.ui.say "    Available TAGS:\n\t "
        tags.each { |tag|
            next if tag.end_with? "^{}"
            Capistrano::CLI.ui.say "#{tag.split('refs/tags/').last}  "
        }
        Capistrano::CLI.ui.say "\n"
    end

    if not branches.empty? then
        Capistrano::CLI.ui.say "    Available BRANCHES:\n"
        branches.each { |branch|
            Capistrano::CLI.ui.say "\t- #{branch.split('refs/heads/').last}\n"
        }
        Capistrano::CLI.ui.say "\n"
    end

    tag = Capistrano::CLI.ui.ask "*** Please specify the branch or tag to deploy: "
    abort "Branch/tag identifier required; aborting deployment." if tag.empty?
    tag
end unless exists?(:branch)

namespace :magento do
  
    set :cold_deploy, false

    namespace :file do 
        desc <<-DESC
            test existence of missing file
        DESC
        task :exists do
            # puts "in exists #{checkFileExistPath}"
            if remote_file_exists?(checkFileExistPath)
                set :isFileMissing, false
            else 
                set :isFileMissing, true
            end
            # puts "in exists and isFileMissing is #{isFileMissing}"
        end
    end

    desc <<-DESC
        Prepares one or more servers for deployment of Magento2. Before you can use any \
        of the Capistrano deployment tasks with your project, you will need to \
        make sure all of your servers have been prepared with `cap deploy:setup'. When \
        you add a new server to your cluster, you can easily run the setup task \
        on just that server by specifying the HOSTS environment variable:

        $ cap HOSTS=new.server.com magento2:setup

        It is safe to run this task on servers that have already been set up; it \
        will not destroy any deployed revisions or data.

        With :web roles
    DESC
    task :setup, :roles => :web, :except => { :no_release => true } do
        if app_shared_dirs 
            app_shared_dirs.each { |link| run "#{try_sudo} mkdir -p #{shared_path}#{link} && chmod 755 #{shared_path}#{link}"}
        end
        if app_shared_files
            app_shared_files.each { |link| run "#{try_sudo} touch #{shared_path}#{link} && chmod 755 #{shared_path}#{link}" }
        end
    end


    desc <<-DESC
        Touches up the released code. This is called by update_code \
        after the basic deploy finishes. 

        Any directories deployed from the SCM are first removed and then replaced with \
        symlinks to the same directories within the shared location.

        With :web roles
    DESC
    task :finalize_update, :roles => :web, :except => { :no_release => true } do
        if app_symlinks
            # Remove the contents of the shared directories if they were deployed from SCM
            app_symlinks.each { |link| run "#{try_sudo} rm -rf #{latest_release}#{link}" }
            # Add symlinks the directoris in the shared location
            app_symlinks.each { |link| run "ln -nfs #{shared_path}#{link} #{latest_release}#{link}" }
        end

        if app_shared_files
            # Remove the contents of the shared directories if they were deployed from SCM
            app_shared_files.each { |link| run "#{try_sudo} rm -rf #{latest_release}/#{link}" }
            # Add symlinks the directoris in the shared location
            app_shared_files.each { |link| run "ln -s #{shared_path}#{link} #{latest_release}#{link}" }
        end
    end 

    desc <<-DESC
        Ensure to set up all folders and file permissions correctly - With :web roles
    DESC
    task :security, :roles => :web do
        run "cd #{latest_release} && find . -type d -exec chmod 770 {} \\;"
        run "cd #{latest_release} && find . -type f -exec chmod 660 {} \\;"
    end

    task :set_cold_deploy, :roles => :web, :except => { :no_release => true } do
        set :cold_deploy, true
    end

    desc <<-DESC
        Install Magento 2 dependencies and run compilation and asset deployment
    DESC
    task :install_dependencies, :roles => :web, :except => { :no_release => true } do
        if !cold_deploy
            run "cd #{latest_release} && #{composer_bin} install --no-dev;"
            run "cd #{latest_release} && php bin/magento setup:upgrade;"
            run "cd #{latest_release} && php bin/magento setup:di:compile$(awk 'BEGIN {FS=\" ?= +\"}{if($1==\"multi-tenant\"){if($2==\"true\"){print \"-multi-tenant\"}}}' .capistrano/config)"
            run "cd #{latest_release} && php bin/magento setup:static-content:deploy $(awk 'BEGIN {FS=\" ?= +\"}{if($1==\"lang\"){print $2}}' .capistrano/config) | grep -v '\\.'"
        end
    end

    desc <<-DESC
        Disable the website by creating a maintenance.flag file
        All web requests will be redirected to a 503 page if the visitor ip address is not within a list of known ip addresses
        as defined by :whitelisted_ips array

        With :web roles
    DESC
    task :disable_web, :roles => :web do
        puts "Hiding the site from the public"
        
        #IP Whitelisting
        ip_whitelist_param = ''
        whitelisted_ips.each do |ip|
           ip_whitelist_param = ip_whitelist_param + " --ip=" + ip
        end
        run "php #{current_path}/bin/magento maintenance:enable #{ip_whitelist_param}"
    end

    desc <<-DESC
        Remove the maintenance.flag file which will re-open the website to all ip addresses

        With :web roles
    DESC
    task :enable_web, :roles => :web do
        puts "Enabling the site to the public"
        run "php #{current_path}/bin/magento maintenance:disable"
    end

    desc <<-DESC
        Check if the site is currently under maintenance (not publicly available)
        If so, then warn the deployer and ask to confirm what action to take
    DESC
    task :checksiteavailability, :roles => :web do
        # check current status
        set :isFileMissing, false
        set :checkFileExistPath, "#{current_path}/var/.maintenance.flag"
        # Run the task which will set :isFileMissing to true of false
        magento.file.exists

        if !isFileMissing
            # Default value is NO
            default_userCommand = 'ABORT'

            puts "Site is currently on maintenance mode.\n"
            puts " - Enter CONTINUE to deploy as per GIT repository content.\n"
            puts " - Enter ABORT to abort (to deploy and keep the site hidden run cap #{stage} deploy mage:disable_web )\n"

            userCommand = Capistrano::CLI.ui.ask "Enter your command here:"
            userCommand = default_userCommand if userCommand.empty?

            abortMsg = "Aborting. Please see https://acidgreen.atlassian.net/wiki/display/DG/4.+Tasks+available for more details."

            case "#{userCommand}"
                when "CONTINUE" then puts "Continuing and deploying as per GIT respository content"
                when "ABORT"       then abort abortMsg
                else abort abortMsg
            end
        end
    end

    task :ensure_robots, :roles => :web do
        desc <<-DESC
            Ensure robots.txt is present in webroot, otherwise copy from the previous release.
        DESC
        set :isFileMissing, false
        set :checkFileExistPath, "#{latest_release}/robots.txt"

        # Run the task which will set :isFileMissing to true of false
        magento.file.exists

        if isFileMissing
            set :isFileMissing, false
            set :checkFileExistPath, "#{current_path}/robots.txt"
            magento.file.exists
            if !isFileMissing
                # Copy generated robots.txt from previous release to new release
                run "cp #{current_path}/robots.txt #{latest_release}/robots.txt"
                run "ln -s #{current_path}/robots.txt #{current_path}/pub/robots.txt"
            end
        end
    end

    desc <<-DESC
        Flush Magento 2 Cache
        With :web roles
    DESC
    task :flush_cache, :roles => :web do
        puts "Flush Magento Cache"
        run "php -f #{current_path}/bin/magento cache:flush"
    end
    
end

after  'deploy:setup',                  'magento:setup'
after  'deploy:finalize_update',        'magento:finalize_update'
before 'deploy:cold',                   'magento:set_cold_deploy'
after  'deploy',                        'magento:ensure_robots'
after  'magento:finalize_update',       'magento:install_dependencies'
after  'magento:finalize_update',       'magento:security'
after  'magento:security',              'magento:checksiteavailability'
after  'deploy:update', 'deploy:cleanup'