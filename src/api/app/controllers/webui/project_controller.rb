class Webui::ProjectController < Webui::WebuiController

  include Webui::HasComments
  include Webui::WebuiHelper
  include Webui::RequestHelper
  include Webui::ProjectHelper
  include Webui::LoadBuildresults
  include Webui::RequiresProject
  include Webui::ManageRelationships

  helper 'webui/comment'

  before_filter :set_project, only: [:autocomplete_packages, :autocomplete_repositories,
                                    :subprojects]
  # This is the deprecated way of loading WebuiProject
  # FIXME: Get rid of "except" clauses, use "only" instead
  before_filter :require_project, except: [:autocomplete_projects, :autocomplete_incidents,
                                          :autocomplete_packages, :autocomplete_repositories,
                                          :subprojects,
                                          :clear_failed_comment, :edit_comment_form, :index,
                                          :new, :package_buildresult,
                                          :save_new, :save_prjconf,
                                          :rebuild_time_png, :new_incident]
  before_filter :load_project_info, :only => [:show, :packages_simple]
  before_filter :require_login, :only => [:save_new, :toggle_watch, :delete, :new]
  before_filter :require_available_architectures, :only => [:add_repository, :add_repository_from_default_list,
                                                            :edit_repository, :update_target]

  before_filter :load_releasetargets, :only => [ :show, :incident_request_dialog, :release_repository_dialog ]
  prepend_before_filter :lockout_spiders, :only => [:requests, :rebuild_time, :buildresults, :maintenance_incidents]

  after_action :verify_authorized, :only => :save_new

  def index
    unless params[:show_all]
      params['excludefilter'] = 'home:'
    end

    @main_projects = []
    @excl_projects = []
    if params['excludefilter'] and params['excludefilter'] != 'undefined'
      @excludefilter = params['excludefilter']
    else
      @excludefilter = nil
    end
    all_projects.each do |name, title|
      if @excludefilter && name.start_with?(@excludefilter)
        @excl_projects << [name, title]
      else
        @main_projects << [name, title]
      end
    end
    # excl and main are sorted by datatable, but important need to be in order
    @important_projects.sort! {|a,b| a[0] <=> b[0] }
    if @spider_bot
      render :list_simple, status: params[:nextstatus]
    else
      render :list, status: params[:nextstatus]
    end
  end

  def all_projects
    @important_projects = []
    # return all projects and their title
    ret = {}
    atype = AttribType.find_by_namespace_and_name!('OBS', 'VeryImportantProject')
    important = {}
    Project.find_by_attribute_type(atype).pluck('projects.id').each do |p|
      important[p] = true
    end
    projects = Project.where('name <> ?', 'deleted').pluck(:id, :name, :title)
    projects.each do |id, name, title|
      @important_projects << [name, title] if important[id]
      ret[name] = title
    end
    ret
  end

  def autocomplete_projects
    render json: Project.autocomplete(params[:term]).not_maintenance_incident.order(:name).pluck(:name)
  end

  def autocomplete_incidents
    render json: Project.autocomplete(params[:term]).maintenance_incident.order(:name).pluck(:name)
  end

  def autocomplete_packages
    packages = []
    packages = @project.packages.autocomplete(params[:term]).pluck(:name) if @project
    render json: packages
  end

  def autocomplete_repositories
    repositories = []
    repositories = @project.repositories.pluck(:name) if @project
    render json: repositories
  end

  def users
    @users = @project.users
    @groups = @project.groups
    @roles = Role.local_roles
  end

  def subprojects
    @subprojects = @project.subprojects.order(:name)
    @parentprojects = @project.ancestors.order(:name)
  end

  def new
    @namespace = params[:ns]
    @project_name = params[:project]
    if @namespace
      @project = Project.find_by_name(@namespace)
      if !@project
        if @namespace == "home:#{User.current.login}"
          @pagetitle = "Your home project doesn't exist yet. You can create it now"
          @project_name = @namespace
        else
          flash[:error] = "Invalid namespace name '#{@namespace}'"
          redirect_back_or_to :controller => 'project' and return
        end
      end
    end
    # regexp named group prj_name
    if @project_name =~ /home:(.+)/
      @project_title = "#$1's Home Project"
    else
      @project_title = ''
    end

    @project = Project.new
  end

  def new_incident
    required_parameters :ns
    target_project = ''
    begin
      path = "/source/#{CGI.escape(params[:ns])}/?cmd=createmaintenanceincident"
      result = ActiveXML::Node.new(frontend.transport.direct_http(URI(path), :method => 'POST', :data => ''))
      result.each("/status/data[@name='targetproject']") { |n| target_project = n.text }
    rescue ActiveXML::Transport::Error => e
      flash[:error] = e.summary
      redirect_to :action => 'show', :project => params[:ns] and return
    end
    flash[:success] = "Created maintenance incident project #{target_project}"
    redirect_to :action => 'show', :project => target_project and return
  end

  def new_package
  end

  def new_package_branch
    @remote_projects = Project.where.not(remoteurl: nil).pluck(:id, :name, :title)
  end

  def incident_request_dialog
    #TODO: Currently no way to find out where to send until the project 'maintained' relationship
    #      is really used. The API will find out magically here though.
    render_dialog
  end

  def new_incident_request
    begin
      BsRequest.transaction do
        req = BsRequest.new
        req.description = params[:description]

        action = BsRequestActionMaintenanceIncident.new({source_project: params[:project]})
        req.bs_request_actions << action
        action.bs_request = req

        req.save!
      end
      flash[:success] = 'Created maintenance incident request'
    rescue MaintenanceHelper::MissingAction,
           BsRequestAction::UnknownProject,
           BsRequestAction::UnknownTargetPackage => e
      flash[:error] = e.summary
      redirect_back_or_to :action => 'show', :project => params[:project] and return
    end
    redirect_to :action => 'show', :project => params[:project]
  end

  def release_request_dialog
    render_dialog
  end

  def new_release_request
    if params[:skiprequest]
      # FIXME2.3: do it directly here, api function missing
    else
      begin
        req=nil
        BsRequest.transaction do
          req = BsRequest.new
          req.description = params[:description]

          action = BsRequestActionMaintenanceRelease.new({source_project: params[:project]})
          req.bs_request_actions << action
          action.bs_request = req

          req.save!
        end
        flash[:success] = "Created maintenance release request " +
                          "<a href='#{url_for(:controller => 'request', :action => 'show', :id => req.id)}'>#{req.id}</a>"
      rescue Patchinfo::IncompletePatchinfo,
             BsRequestAction::UnknownProject,
             BsRequestAction::BuildNotFinished,
             BsRequestAction::UnknownTargetPackage => e
        flash[:error] = e.message
        redirect_back_or_to :action => 'show', :project => params[:project] and return
      rescue APIException
        flash[:error] = 'Internal problem while release request creation'
        redirect_back_or_to :action => 'show', :project => params[:project] and return
      end
    end
    redirect_to :action => 'show', :project => params[:project]
  end

  def find_packages_info
    packages=@project.api_obj.expand_all_packages
    @project.api_obj.map_packages_to_projects(packages)
  end

  def find_maintenance_infos
    @project.api_obj.maintenance_projects.each do |pm|
      # FIXME: skip the non official ones
      @project_maintenance_project = pm.maintenance_project.name
    end

    @is_maintenance_project = @project.api_obj.is_maintenance?
    if @is_maintenance_project
      subprojects = Project.where('projects.name like ?', @project.name + ':%').
          where(kind: 'maintenance_incident').joins(:repositories => :release_targets).
          where("release_targets.trigger = 'maintenance'")
      @open_maintenance_incidents = subprojects.pluck('projects.name').sort.uniq

      @maintained_projects = []
      @project.api_obj.maintained_projects.each do |mp|
        @maintained_projects << mp.project.name
      end
    end
    @is_incident_project = @project.api_obj.is_maintenance_incident?
    if @is_incident_project
      @open_release_requests = BsRequest.collection(project: @project.name,
                                    states: %w(new review),
                                    types: %w(maintenance_release),
                                    roles: %w(source)).ids
    end
  end

  def find_nr_of_problems
    begin
      result = ActiveXML.backend.direct_http("/build/#{URI.escape(@project.name)}/_result?view=status&code=failed&code=broken&code=unresolvable")
    rescue ActiveXML::Transport::NotFoundError
      return 0
    end
    ret = {}
    Xmlhash.parse(result).elements('result') do |r|
      r.elements('status') { |p| ret[p['package']] = 1 }
    end
    ret.keys.size
  end

  def load_project_info
    return render_project_missing unless @project

    find_maintenance_infos
    @packages = Array.new
    @ipackages = Array.new
    find_packages_info.each do |p|
      if p[1]
        @ipackages << [p[0], p[1]]
      else
        @packages << p[0]
      end
    end
    @ipackages.sort!
    @packages.sort!
    @linking_projects = @project.api_obj.find_linking_projects.map { |p| p.name }
    reqs = @project.api_obj.request_ids_by_class
    @requests = (reqs['reviews'] + reqs['targets'] + reqs['incidents'] + reqs['maintenance_release']).sort.uniq
    @nr_of_problem_packages = find_nr_of_problems
  end

  def packages_simple

  end

  def show
    required_parameters :project
    @bugowners_mail = @project.api_obj.bugowner_emails

    # An incident has a patchinfo if there is a package 'patchinfo' with file '_patchinfo', try to find that:
    @has_patchinfo = false
    if @packages.include? 'patchinfo'
      Directory.hashed(project: @project.name, package: 'patchinfo').elements('entry') do |e|
        @has_patchinfo = true if e['name'] == '_patchinfo'
      end
    end
    @comments = @project.api_obj.comments
    render :show, status: params[:nextstatus] if params[:nextstatus]
  end

  def main_object
    @project.api_obj # used by mixins
  end

  def load_releasetargets
    @releasetargets = []
    rts = ReleaseTarget.where(repository_id: @project.api_obj.repositories)
    unless rts.empty?
      Rails.logger.debug rts.inspect
      @project.each('repository') do |repo|
        rt = repo.find_first(:releasetarget)
        @releasetargets.push(rt.value('project') + '/' + rt.value('repository')) if rt
      end
    end
  end

  # TODO: remove this ajax call and replace it with a jquery dialog
  def linking_projects
    @linking_projects = @project.api_obj.find_linking_projects.map { |p| p.name }
    render_dialog
  end

  # TODO we need the architectures in api/distributions
  def add_repository_from_default_list
    @distributions = {}
    Distribution.all_including_remotes.each do |dis|
      @distributions[dis['vendor']] ||= []
      @distributions[dis['vendor']] << dis
    end

    if @distributions.empty?
      if User.current.is_admin?
        flash.now[:notice] = "There are no distributions configured! Check out" +
                             "<a href=\"/configuration/connect_instance\">Configuration > Interconnect</a>"
      else
        redirect_to :controller => 'project', :action => 'add_repository', :project => @project
      end
    end
  end

  def add_repository
    @torepository = params[:torepository]
  end

  def add_person
    @roles = Role.local_roles
  end

  def add_group
    @roles = Role.local_roles
  end

  def load_buildresult
    @buildresult = Buildresult.find_hashed(:project => params[:project], :view => 'summary')
    fill_status_cache
  end
  protected :load_buildresult

  def convert_buildresult
    myarray = Array.new
    @buildresult.elements('result') do |result|
      result['summary'].elements('statuscount') do |sc|
        myarray << [result['repository'], result['arch'], Buildresult.code2index(sc['code']), sc['count']]
      end
    end
    myarray.sort!
    repos = Array.new
    orepo = nil
    oarch = nil
    archs = nil
    counts = nil
    myarray.each do |repo, arch, code, count|
      if orepo != repo
        archs << [oarch, counts] if oarch
        oarch = nil
        repos << [orepo, archs] if orepo
        archs = Array.new
      end
      orepo = repo
      if oarch != arch
        archs << [oarch, counts] if oarch
        counts = Array.new
      end
      oarch = arch
      counts << [Buildresult.index2code(code), count]
    end
    archs << [oarch, counts] if oarch
    repos << [orepo, archs] if orepo
    @buildresult = repos || Array.new
  end

  def buildresult
    check_ajax
    load_buildresult
    convert_buildresult
    render :partial => 'buildstatus'
  end

  def delete_dialog
    @linking_projects = @project.api_obj.find_linking_projects.map { |p| p.name }
    render_dialog
  end

  def delete
    begin
      if params[:force] == '1'
        @project.delete :force => 1
      else
        @project.delete
      end
      flash[:notice] = "Project '#{@project}' was removed successfully"
    rescue ActiveXML::Transport::Error => e
      flash[:error] = e.summary
    end
    if @project.is_maintenance?
      redirect_to :action => 'show', :project => @project
    else
      parent_projects = Project.parent_projects(@project.name)
      if parent_projects.present?
        redirect_to :action => 'show', :project => parent_projects[parent_projects.length - 1][0]
      else
        redirect_to :action => 'index'
      end
    end
  end

  def edit_repository
    check_ajax
    repo = @project.api_obj.repositories.where(name: params[:repository]).first
    redirect_back_or_to(:controller => 'project', :action => 'repositories', :project => @project) and return if not repo
    # Merge project repo's arch list with currently available arches from API. This needed as you want
    # to keep currently non-working arches in the project meta.

    @repository_arch_hash = Hash.new
    @available_architectures.each {|arch| @repository_arch_hash[arch.name] = false }
    repo.architectures.each {|arch| @repository_arch_hash[arch.name] = true }

    render(:partial => 'edit_repository', :locals => {:repository => repo, :error => nil})
  end

  def update_target
    repo = @project.api_obj.repositories.where(name: params[:repo]).first
    archs = []
    archs = params[:arch].keys.map { |arch| Architecture.find_by_name(arch) } if params[:arch]
    repo.architectures = archs
    repo.save
    @project.api_obj.store

    # Merge project repo's arch list with currently available arches from API. This needed as you want
    # to keep currently non-working arches in the project meta.
    @repository_arch_hash = Hash.new
    @available_architectures.each {|arch| @repository_arch_hash[arch.name] = false }
    repo.architectures.each {|arch| @repository_arch_hash[arch.name] = true }

    begin
      render :partial => 'edit_repository', :locals => { :repository => repo, :has_data => true }
    rescue => e
      render :partial => 'edit_repository', :locals => { :repository => repo, :error => "#{e.summary}" }
    end
  end

  def repositories
    if @project.is_remote?
      # TODO support flagdetails for remote instances in the API
      flash[:error] = "You can't show repositories for remote instances"
      redirect_to :action => :show, :project => params[:project]
      return
    end
    @flags = @project.api_obj.expand_flags
  end

  def repository_state
    required_parameters :repository

    # Get cycles of the repository build dependency information
    #
    @repocycles = Hash.new

    @repository = @project.api_obj.repositories.where(name: params[:repository]).first

    unless @repository
      redirect_to :back, alert: "Repository '#{params[:repository]}' not found"
      return
    end

    @archs = []
    @repository.architectures.each do |arch|
      @archs << arch.name
      calculate_repo_cycle(arch.name)
    end
  end

  def calculate_repo_cycle(arch)
    cycles = Array.new
    # skip all packages via package=- to speed up the api call, we only parse the cycles anyway
    deps = BuilddepInfo.find(:project => @project.name, :package => '-', :repository => @repository.name, :arch => arch)
    nr_cycles = 0
    if deps and deps.has_element? :cycle
      packages = Hash.new
      deps.each(:cycle) do |cycle|
        current_cycles = Array.new
        cycle.each(:package) do |p|
          p = p.text
          if packages.has_key? p
            current_cycles << packages[p]
          end
        end
        current_cycles.uniq!
        if current_cycles.empty?
          nr_cycles += 1
          nr_cycle = nr_cycles
        elsif current_cycles.length == 1
          nr_cycle = current_cycles[0]
        else
          logger.debug "HELP! #{current_cycles.inspect}"
        end
        cycle.each(:package) do |p|
          packages[p.text] = nr_cycle
        end
      end
    end
    cycles = Array.new
    1.upto(nr_cycles) do |i|
      list = Array.new
      packages.each do |package, cycle|
        list.push(package) if cycle == i
      end
      cycles << list.sort
    end
    @repocycles[arch] = cycles unless cycles.empty?
  end

  def rebuild_time
    required_parameters :repository, :arch
    load_project_info
    @repository = params[:repository]
    @arch = params[:arch]
    @hosts = begin Integer(params[:hosts] || '40') rescue 40 end
    @scheduler = params[:scheduler] || 'needed'
    unless %w(fifo lifo random btime needed neededb longest_data longested_triedread longest).include? @scheduler
      flash[:error] = 'Invalid scheduler type, check mkdiststats docu - aehm, source'
      redirect_to :action => :show, :project => @project
      return
    end
    bdep = BuilddepInfo.find(:project => @project.name, :repository => @repository, :arch => @arch)
    jobs = Jobhistory.find(:project => @project.name, :repository => @repository, :arch => @arch,
            :limit => (@packages.size + @ipackages.size) * 3, :code => %w(succeeded unchanged))
    unless bdep and jobs
      flash[:error] = "Could not collect infos about repository #{@repository}/#{@arch}"
      redirect_to :action => :show, :project => @project
      return
    end
    longest = call_diststats(bdep, jobs)
    @longestpaths = Array.new
    longest['longestpath'].elements('path') do |path|
      currentpath = Array.new
      path.elements('package') do |p|
        currentpath << p
      end
      @longestpaths << currentpath
    end if longest
    # we append 4 empty paths, so there are always at least 4 in the array
    # to simplify the view code
    4.times { @longestpaths << Array.new }
  end

  def call_diststats(bdep, jobs)
    @timings = Hash.new
    @pngkey = Digest::MD5.hexdigest(params.to_s)
    @rebuildtime = 0

    indir = Dir.mktmpdir
    f = File.open(indir + '/_builddepinfo.xml', 'w')
    f.write(bdep.dump_xml)
    f.close
    f = File.open(indir + '/_jobhistory.xml', 'w')
    f.write(jobs.dump_xml)
    f.close
    outdir = Dir.mktmpdir

    logger.debug "cd #{Rails.root.join('vendor', 'diststats').to_s} && perl ./mkdiststats --srcdir=#{indir} --destdir=#{outdir}
             --outfmt=xml #{@project.name}/#{@repository}/#{@arch} --width=910
             --buildhosts=#{@hosts} --scheduler=#{@scheduler}"
    oldpwd = Dir.pwd
    Dir.chdir(Rails.root.join('vendor', 'diststats'))
    unless system('perl', './mkdiststats', "--srcdir=#{indir}", "--destdir=#{outdir}",
                  '--outfmt=xml', "#{@project.name}/#{@repository}/#{@arch}", '--width=910',
                  "--buildhosts=#{@hosts}", "--scheduler=#{@scheduler}")
      Dir.chdir(oldpwd)
      return nil
    end
    Dir.chdir(oldpwd)
    begin
      f=File.open(outdir + '/rebuild.png')
      png=f.read
      f.close
    rescue
      return nil
    end

    Rails.cache.write('rebuild-%s.png' % @pngkey, png)
    f=File.open(outdir + '/longest.xml')
    longest = Xmlhash.parse(f.read)
    longest['timings'].elements('package') do |p|
      @timings[p['name']] = [p['buildtime'], p['finished']    ]
    end
    @rebuildtime = Integer(longest['rebuildtime'])
    f.close
    FileUtils.rm_rf indir
    FileUtils.rm_rf outdir
    longest
  end

  def rebuild_time_png
    required_parameters :key
    key = params[:key]
    png = Rails.cache.read('rebuild-%s.png' % key)
    headers['Content-Type'] = 'image/png'
    send_data(png, :type => 'image/png', :disposition => 'inline')
  end

  def packages
    headers['Status'] = '301 Moved Permanently'
    redirect_to :action => 'show', :project => @project
  end

  def requests
    @requests = @project.api_obj.request_ids_by_class(false)
    @default_request_type = params[:type] if params[:type]
    @default_request_state = params[:state] if params[:state]
  end

  def save_new
    # ns means namespace / parent project
    params[:project][:name] = "#{params[:ns]}:#{params[:project][:name]}" if params[:ns]

    @project = Project.new(project_params)
    authorize(@project, :create?)

    @project.relationships.build(user: User.current,
                                 role: Role.find_by_title('maintainer'))

    @project.kind = 'maintenance' if params[:maintenance_project]

    # TODO: do this with nested attributes
    if params[:access_protection]
      @project.flags.new(status: 'disable', flag: 'access')
    end

    # TODO: do this with nested attributes
    if params[:source_protection]
      @project.flags.new(status: 'disable', flag: 'sourceaccess')
    end

    # TODO: do this with nested attributes
    if params[:disable_publishing]
      @project.flags.new(status: 'disable', flag: 'publish')
    end

    if @project.valid? && @project.store
      flash[:notice] = "Project '#{@project}' was created successfully"
      redirect_to :action => 'show', :project => @project.name
    else
      flash[:error] = "Failed to save project '#{@project}'. #{@project.errors.full_messages.to_sentence}."
      redirect_to :back
    end
  end

  def save
    if ( !params[:title] )
      flash[:error] = 'Title must not be empty'
      redirect_to :action => 'edit', :project => params[:project]
      return
    end

    @project.find_first(:title).text = params[:title]
    @project.find_first(:description).text = params[:description]

    if @project.save
      flash[:notice] = "Project '#{@project}' was saved successfully"
    else
      flash[:error] = "Failed to save project '#{@project}'"
    end

    redirect_to action: :show, project: @project
  end

  def valid_target_name? name
    name =~ /^\w[-\.\w&]*$/
  end

  def save_targets
    if params[:target_project].blank? and params[:torepository].blank? and
        params[:repo].blank? and params[:target_repo].blank?
      flash[:error] = 'Missing arguments for target project or repository'
      redirect_to :action => 'add_repository_from_default_list', :project => @project and return
    end
    target_repo = params[:target_repo]

    # extend an existing repository with a path
    if params.has_key?(:torepository)
      repo_path = "#{params[:target_project]}/#{target_repo}"
      if @project.add_path_to_repository(:reponame => params[:torepository], :repo_path => repo_path)
        @project.save
        flash[:success] = "Path #{params['target_project']}/#{target_repo} added successfully"
        redirect_to :action => 'repositories', :project => @project and return
      else
        flash[:error] = "Path #{params['target_project']}/#{target_repo} is already set for this repository"
        redirect_to :action => 'add_repository', :project => @project, :torepository => params[:torepository] and return
      end
    elsif params.has_key?(:repo)
      # add new repositories
      repos = params[:repo]
      # this interface is a mess
      if repos.kind_of? String
        repos=[repos]
      end
      repos.each do |repo|
        if !valid_target_name? repo
          flash[:error] = "Illegal target name #{repo}."
          redirect_to :action => :add_repository_from_default_list, :project => @project and return
        end
        repo_path = params[repo + '_repo'] || "#{params[:target_project]}/#{target_repo}"
        repo_archs = params[repo + '_arch'] || params[:arch]
        logger.debug "Adding repo: #{repo_path}, archs: #{repo_archs}"
        @project.add_repository(:reponame => repo, :repo_path => repo_path, :arch => repo_archs)

        # FIXME: will be cleaned up after implementing FATE #308899
        if repo == 'images'
          prjconf = @project.api_obj.source_file('_config')
          unless prjconf =~ /^Type:/
            prjconf = "%if \"%_repository\" == \"images\"\nType: kiwi\nRepotype: none\nPatterntype: none\n%endif\n" << prjconf
            frontend.put_file(prjconf, :project => @project, :filename => '_config')
          end
        end
      end

      @project.save
      flash[:success] = 'Build targets were added successfully'
      redirect_to :action => 'repositories', :project => @project and return
    end
  rescue ActiveXML::Transport::Error => e
    flash[:error] = 'Failed to add project or repository: ' + e.summary
    redirect_back_or_to :action => 'repositories', :project => @project and return
  end

  def release_repository_dialog
    @project = params[:project]
    @repository = params[:repository]
    render_dialog
  end

  def remove_target_request_dialog
    @project = params[:project]
    @repository = params[:repository]
    render_dialog
  end

  def remove_target_request
    req=nil
    begin
      BsRequest.transaction do
        req = BsRequest.new
        req.description = params[:description]

        opts = {target_project: params[:project]}
        opts[:target_repository] = params[:repository] if params[:repository]
        action = BsRequestActionDelete.new(opts)
        req.bs_request_actions << action
        action.bs_request = req

        req.save!
      end
      flash[:success] = "Created <a href='#{url_for(:controller => 'request',
                                                    :action => 'show',
                                                    :id => req.id)}'>repository delete request #{req.id}</a>"
    rescue BsRequestAction::UnknownTargetProject,
           BsRequestAction::UnknownTargetPackage => e
      flash[:error] = e.message
      redirect_to :action => :repositories, :project => @project and return
    end
    redirect_to :controller => :request, :action => :show, :id => req.id
  end

  def remove_target
    if not params[:target]
      flash[:error] = 'Target removal failed, no target selected!'
      redirect_to :action => :show, :project => params[:project]
    end
    @project.remove_repository params[:target]
    begin
      if @project.save
        flash[:notice] = "Target '#{params[:target]}' was removed"
      else
        flash[:error] = "Failed to remove target '#{params[:target]}'"
      end
    rescue ActiveXML::Transport::Error => e
      flash[:error] = "Failed to remove target '#{params[:target]}' " + e.summary
    end
    redirect_to :action => :repositories, :project => @project
  end

  def release_repository
    begin
      @project.release_repository(params[:repository], params[:release_target])
      flash[:notice] = "Repository '#{params[:repository]}' gets released"
    rescue ActiveXML::Transport::Error => e
      flash[:error] = "Failed to release repository '#{params[:repository]}' " + e.summary
    end
    redirect_to :action => :repositories, :project => @project
  end

  def remove_path_from_target
    required_parameters :repository, :path_project, :path_repository
    @project.remove_path_from_target( params[:repository], params[:path_project], params[:path_repository] )
    @project.save
    flash[:success] = "Removed path #{params['path_project']}/#{params['path_repository']} from #{params['repository']}"
    redirect_to :action => :repositories, :project => @project
  end

  def move_path_up
    move_path(:up)
  end

  def move_path_down
    move_path(:down)
  end

  def monitor
    @name_filter = params[:pkgname]
    @lastbuild_switch = params[:lastbuild]
    if params[:defaults]
      defaults = (Integer(params[:defaults]) rescue 1) > 0
    else
      defaults = true
    end
    params['expansionerror'] = 1 if params['unresolvable']
    monitor_set_filter(defaults)

    find_opt = { :project => @project, :view => 'status', :code => @status_filter,
      :arch => @arch_filter, :repo => @repo_filter }
    find_opt[:lastbuild] = 1 unless @lastbuild_switch.blank?

    @buildresult = Buildresult.find( find_opt )
    unless @buildresult
      flash[:warning] = "No build results for project '#{@project}'"
      redirect_to :action => :show, :project => params[:project]
      return
    end

    @buildresult = @buildresult.to_hash
    if not @buildresult.has_key? 'result'
      @buildresult_unavailable = true
      return
    end

    fill_status_cache

    load_local_packages

    @packagenames = @packagenames.flatten.uniq.sort

    ## Filter for PackageNames ####
    @packagenames.reject! {|name| not filter_matches?(name,@name_filter) } if not @name_filter.blank?

    packagename_hash = Hash.new
    @packagenames.each { |p| packagename_hash[p.to_s] = 1 }

    # filter out repos without current packages
    @statushash.each do |repo, hash|
      hash.each do |arch, packages|

        has_packages = false
        packages.each do |p, status|
          if packagename_hash.has_key? p
            has_packages = true
            break
          end
        end
        unless has_packages
          @repohash[repo].delete arch
        end
      end
    end
  end

  def monitor_set_filter(defaults)
    @avail_status_values = Buildresult.avail_status_values
    @filter_out = %w(disabled excluded unknown)
    @status_filter = []
    @avail_status_values.each { |s|
      id=s.gsub(' ', '')
      if params.has_key?(id)
        next unless (Integer(params[id]) rescue 1) > 0
      else
        next unless defaults
      end
      next if defaults && @filter_out.include?(s)
      @status_filter << s
    }

    @avail_arch_values = []
    @avail_repo_values = []

    @project.api_obj.repositories.each { |r|
      @avail_repo_values << r.name
      @avail_arch_values << r.architectures.pluck(:name)
    }
    @avail_arch_values = @avail_arch_values.flatten.uniq.sort
    @avail_repo_values = @avail_repo_values.flatten.uniq.sort

    @arch_filter = []
    @avail_arch_values.each { |s|
      archid = valid_xml_id('arch_' + s)
      if defaults || (params.has_key?(archid) && params[archid])
        @arch_filter << s
      end
    }

    @repo_filter = []
    @avail_repo_values.each { |s|
      repoid = valid_xml_id('repo_' + s)
      if defaults || (params.has_key?(repoid) && params[repoid])
        @repo_filter << s
      end
    }
  end

  def filter_matches?(input,filter_string)
    result = false
    filter_string.gsub!(/\s*/,'')
    filter_string.split(',').each { |filter|
      no_invert = filter.match(/(^!?)(.+)/)
      if no_invert[1] == '!'
        result = input.include?(no_invert[2]) ? result : true
      else
        result = input.include?(no_invert[2]) ? true : result
      end
    }
    return result
  end

  # should be in the package controller, but all the helper functions to render the result of a build are in the project
  def package_buildresult
    check_ajax
    @project = params[:project]
    @package = params[:package]
    begin
      @buildresult = Buildresult.find_hashed(:project => params[:project], :package => params[:package], :view => 'status', :lastbuild => 1)
    rescue ActiveXML::Transport::Error # wild work around for backend bug (sends 400 for 'not found')
    end
    @repohash = Hash.new
    @statushash = Hash.new

    @buildresult.elements('result') do |result|
      repo = result['repository']
      arch = result['arch']

      @repohash[repo] ||= Array.new
      @repohash[repo] << arch

      # package status cache
      @statushash[repo] ||= Hash.new
      @statushash[repo][arch] = Hash.new

      stathash = @statushash[repo][arch]
      result.elements('status') do |status|
        stathash[status['package']] = status
      end
    end if @buildresult
    render :layout => false
  end

  def toggle_watch
    if User.current.watches? @project.name
      logger.debug "Remove #{@project} from watchlist for #{User.current}"
      User.current.remove_watched_project @project.name
    else
      logger.debug "Add #{@project} to watchlist for #{User.current}"
      User.current.add_watched_project @project.name
    end

    if request.env['HTTP_REFERER']
      redirect_to :back
    else
      redirect_to :action => :show, :project => @project
    end
  end

  def meta
    @meta = @project.api_obj.render_xml
  end

  def save_meta
    begin
      frontend.put_file(params[:meta], :project => params[:project], :filename => '_meta')
    rescue ActiveXML::Transport::Error => e
      render text: e.summary, :status => 400, :content_type => 'text/plain'
      return
    end

    render text: 'Config successfully saved', :content_type => 'text/plain'
  end

  def prjconf
    begin
      @config = @project.api_obj.source_file('_config')
    rescue ActiveXML::Transport::NotFoundError
      flash[:error] = "Project _config not found: #{params[:project]}"
      redirect_to :controller => 'project', :nextstatus => 404 and return
    end
  end

  def save_prjconf
    check_ajax
    frontend.put_file(params[:config], :project => params[:project], :filename => '_config')
    flash[:notice] = 'Project Config successfully saved'
    render text: 'Config successfully saved', content_type: 'text/plain'
  end

  def change_flag
    check_ajax
    required_parameters :cmd, :flag
    frontend.source_cmd params[:cmd], :project => @project,
                        :repository => params[:repository],
                        :arch => params[:arch], :flag => params[:flag],
                        :status => params[:status]
    @flags = @project.api_obj.expand_flags[params[:flag]]
  end

  def clear_failed_comment
    # TODO(Jan): put this logic in the Attribute model
    transport ||= ActiveXML::api
    params['package'].to_a.each do |p|
      begin
        transport.direct_http URI("/source/#{params[:project]}/#{p}/_attribute/OBS:ProjectStatusPackageFailComment"), :method => 'DELETE'
      rescue ActiveXML::Transport::ForbiddenError => e
        flash[:error] = e.summary
        redirect_to :action => :status, :project => params[:project]
        return
      end
    end
    if request.xhr?
      render text: '<em>Cleared comment</em>'
      return
    end
    if params['package'].to_a.length > 1
      flash[:notice] = 'Cleared comment for packages %s' % params[:package].to_a.join(',')
    else
      flash[:notice] = "Cleared comment for package #{params[:package]}"
    end
    redirect_to :action => :status, :project => params[:project]
  end

  def edit
  end

  def edit_comment_form
    check_ajax
    @comment = params[:comment]
    @project = params[:project]
    @package = params[:package]
    @update = params[:update]
  end

  def edit_comment
    @package = @project.api_obj.find_package(params[:package])

    unless User.current.can_create_attribute_in? @package, namespace: 'OBS', name: 'ProjectStatusPackageFailComment'
      @comment = params[:last_comment]
      @error = "Can't create attributes in #{@package}"
      return
    end

    at = AttribType.find_by_namespace_and_name!('OBS', 'ProjectStatusPackageFailComment')
    attr = @package.attribs.where(attrib_type: at).first_or_initialize
    v = attr.values.first_or_initialize
    v.value = params[:text]
    v.position = 1
    attr.save!
    @comment = params[:text]
    @update = params[:update]
  end

  def calc_status(project_name)
    @api_obj = ::Project.where(name: project_name).includes(:packages).first
    @status = Hash.new

    # needed to map requests to package id
    @name2id = Hash.new

    @prj_status = Rails.cache.fetch("prj_status-#{@api_obj.to_s}", expires_in: 5.minutes) do
      ProjectStatusCalculator.new(@api_obj).calc_status(pure_project: true)
    end

    status_filter_packages
    status_gather_attributes
    status_gather_requests

    @packages = Array.new
    @status.each_value do |p|
      status_check_package(p)
    end

    return {packages: @packages, projects: @develprojects.keys}
  end

  def status_check_package(p)
    currentpack = Hash.new
    pname = p.name

    currentpack['requests_from'] = Array.new
    key = @api_obj.name + '/' + pname
    if @submits.has_key? key
      return if @ignore_pending
      currentpack['requests_from'].concat(@submits[key])
    end

    currentpack['name'] = pname
    currentpack['failedcomment'] = p.failed_comment unless p.failed_comment.blank?

    newest = 0

    p.fails.each do |repo, arch, time, md5|
      next if newest > time
      next if md5 != p.verifymd5
      currentpack['failedarch'] = arch
      currentpack['failedrepo'] = repo
      newest = time
      currentpack['firstfail'] = newest
    end
    return if !currentpack['firstfail'] && @limit_to_fails

    currentpack['problems'] = Array.new
    currentpack['requests_to'] = Array.new

    currentpack['md5'] = p.verifymd5

    check_devel_package_status(currentpack, p)
    currentpack.merge!(project_status_set_version(p))

    if p.links_to
      if currentpack['md5'] != p.links_to.verifymd5
        currentpack['problems'] << 'diff_against_link'
        currentpack['lproject'] = p.links_to.project
        currentpack['lpackage'] = p.links_to.name
      end
    end

    return unless (currentpack['firstfail'] or currentpack['failedcomment'] or currentpack['upstream_version'] or
        !currentpack['problems'].empty? or !currentpack['requests_from'].empty? or !currentpack['requests_to'].empty?)
    if @limit_to_old
      return unless currentpack['upstream_version']
    end
    @packages << currentpack
  end

  def check_devel_package_status(currentpack, p)
    dp = p.develpack
    return unless dp
    dproject = dp.project
    currentpack['develproject'] = dproject
    currentpack['develpackage'] = dp.name
    key = '%s/%s' % [dproject, dp.name]
    if @submits.has_key? key
      currentpack['requests_to'].concat(@submits[key])
    end

    currentpack['develmd5'] = dp.verifymd5
    currentpack['develmtime'] = dp.maxmtime

    if dp.error
      currentpack['problems'] << 'error-' + dp.error
    end

    if currentpack['md5'] && currentpack['develmd5'] && currentpack['md5'] != currentpack['develmd5']
      if p.declined_request
        @declined_requests[p.declined_request].bs_request_actions.each do |action|
          next unless action.source_project == dp.project && action.source_package == dp.name

          sourcerev = Rails.cache.fetch("rev-#{dp.project}-#{dp.name}-#{currentpack['md5']}") do
            Directory.hashed(project: dp.project, package: dp.name)['rev']
          end
          if sourcerev == action.source_rev
            currentpack['currently_declined'] = p.declined_request
            currentpack['problems'] << 'currently_declined'
          end
        end
      end
      if currentpack['currently_declined'].nil?
        if p.changesmd5 != dp.changesmd5
          currentpack['problems'] << 'different_changes'
        else
          currentpack['problems'] << 'different_sources'
        end
      end
    end
  end

  def status_filter_packages
    filter_for_user = User.find_by_login!(@filter_for_user) unless @filter_for_user.blank?
    current_develproject = @filter || @all_projects
    @develprojects = Hash.new
    packages_to_filter_for = nil
    if filter_for_user
      packages_to_filter_for = filter_for_user.user_relevant_packages_for_status
    end
    @prj_status.each_value do |value|
      if value.develpack
        dproject = value.develpack.project
        @develprojects[dproject] = 1
        if (current_develproject != dproject or current_develproject == @no_project) and current_develproject != @all_projects
          next
        end
      else
        next if @current_develproject == @no_project
      end
      if filter_for_user
        if value.develpack
          next unless packages_to_filter_for.include? value.develpack.package_id
        else
          next unless packages_to_filter_for.include? value.package_id
        end
      end
      @status[value.package_id] = value
      @name2id[value.name] = value.package_id
    end
  end

  def status_gather_requests
    # we do not filter requests for project because we need devel projects too later on and as long as the
    # number of open requests is limited this is the easiest solution
    raw_requests = BsRequest.order(:id).where(state: [:new, :review, :declined]).joins(:bs_request_actions).
        where(bs_request_actions: {type: 'submit'}).pluck('bs_requests.id', 'bs_requests.state',
                                                          'bs_request_actions.target_project',
                                                          'bs_request_actions.target_package')

    @declined_requests = {}
    @submits = Hash.new
    raw_requests.each do |id, state, tproject, tpackage|
      if state == 'declined'
        next if tproject != @api_obj.name || !@name2id.has_key?(tpackage)
        @status[@name2id[tpackage]].declined_request = id
        @declined_requests[id] = nil
      else
        key = "#{tproject}/#{tpackage}"
        @submits[key] ||= Array.new
        @submits[key] << id
      end
    end
    BsRequest.where(id: @declined_requests.keys).each do |r|
      @declined_requests[r.id] = r
    end
  end

  def status_gather_attributes
    project_status_attributes(@status.keys, 'OBS', 'ProjectStatusPackageFailComment') do |package, value|
      @status[package].failed_comment = value
    end

    if @include_versions || @limit_to_old
      project_status_attributes(@status.keys, 'openSUSE', 'UpstreamVersion') do |package, value|
        @status[package].upstream_version = value
      end
      project_status_attributes(@status.keys, 'openSUSE', 'UpstreamTarballURL') do |package, value|
        @status[package].upstream_url= value
      end
    end
  end

  def project_status_attributes(packages, namespace, name)
    ret = Hash.new
    at = AttribType.find_by_namespace_and_name(namespace, name)
    return unless at
    attribs = at.attribs.where(package_id: packages)
    AttribValue.where(attrib_id: attribs).joins(:attrib).pluck('attribs.package_id, value').each do |id, value|
      yield id, value
    end
    ret
  end

  def project_status_set_version(p)
    ret = {}
    ret['version'] = p.version
    if p.upstream_version
      begin
        gup = Gem::Version.new(p.version)
        guv = Gem::Version.new(p.upstream_version)
      rescue ArgumentError
        # if one of the versions can't be parsed we simply can't say
      end

      if gup && guv && gup < guv
        ret['upstream_version'] = p.upstream_version
        ret['upstream_url'] = p.upstream_url
      end
    end
    ret
  end

  def status
    all_packages = 'All Packages'
    no_project = 'No Project'
    @no_project = '_none_'
    @all_projects = '_all_'
    @current_develproject = params[:filter_devel] || all_packages
    @filter = @current_develproject
    if @filter == all_packages
      @filter = @all_projects
    elsif @filter == no_project
      @filter = @no_project
    end
    @ignore_pending = params[:ignore_pending] || false
    @limit_to_fails = params[:limit_to_fails] != 'false'
    @limit_to_old = !(params[:limit_to_old].nil? || params[:limit_to_old] == 'false')
    @include_versions = !(!params[:include_versions].nil? && params[:include_versions] == 'false')
    @filter_for_user = params[:filter_for_user]

    @develprojects = Hash.new
    ps = calc_status(params[:project])

    @packages = ps[:packages]
    @develprojects = ps[:projects].sort { |x,y| x.downcase <=> y.downcase }
    @develprojects.insert(0, all_packages)
    @develprojects.insert(1, no_project)

    respond_to do |format|
      format.json {
        render json: Yajl::Encoder.encode(@packages)
      }
      format.html
    end
  end

  before_filter :require_maintenance_project, only: [:maintained_projects,
                                                     :add_maintained_project_dialog,
                                                     :add_maintained_project,
                                                     :remove_maintained_project]

  def require_maintenance_project
    unless @is_maintenance_project
      redirect_back_or_to :action => 'show', :project => @project
      return false
    end
    return true
  end

  def maintained_projects
    @maintained_projects = []
    @project.each('maintenance/maintains') do |maintained_project_name|
       @maintained_projects << maintained_project_name.value(:project)
    end
  end

  def add_maintained_project_dialog
    render_dialog
  end

  def add_maintained_project
    if params[:maintained_project].nil? or params[:maintained_project].empty?
      flash[:error] = 'Please provide a valid project name'
      redirect_back_or_to(:action => 'maintained_projects', :project => @project) and return
    end

    begin
      @project.add_maintained_project(params[:maintained_project])
      @project.save
      flash[:notice] = "Added project '#{params[:maintained_project]}' to maintenance"
    rescue ActiveXML::Transport::NotFoundError
      flash[:error] = "Failed to add project '#{params[:maintained_project]}' to maintenance"
    end
    redirect_to(:action => 'maintained_projects', :project => @project) and return
  end

  def remove_maintained_project
    if params[:maintained_project].blank?
      flash[:error] = 'Please provide a valid project name'
      redirect_back_or_to(:action => 'maintained_projects', :project => @project) and return
    end

    @project.remove_maintained_project(params[:maintained_project])
    if @project.save
      flash[:notice] = "Removed project '#{params[:maintained_project]}' from maintenance"
    else
      flash[:error] = "Failed to remove project '#{params[:maintained_project]}' from maintenance"
    end
    redirect_to(:action => 'maintained_projects', :project => @project) and return
  end

  def maintenance_incidents
    @incidents = @project.api_obj.maintenance_incidents
  end

  def unlock_dialog
    render_dialog
  end

  def unlock
    begin
      path = "/source/#{CGI.escape(params[:project])}/?cmd=unlock&comment=#{CGI.escape(params[:comment])}"
      frontend.transport.direct_http(URI(path), :method => 'POST', :data => '')
      flash[:success] = "Unlocked project #{params[:project]}"
    rescue ActiveXML::Transport::Error => e
      flash[:error] = e.summary
    end
    redirect_to :action => 'show', :project => params[:project] and return
  end

  private

  def project_params
    params.require(:project).permit(
        :name,
        :ns,
        :title,
        :description,
        :maintenance_project,
        :access_protection,
        :source_protection,
        :disable_publishing
    )
  end

  def filter_packages( project, filterstring )
    result = Collection.find :id, :what => 'package',
      :predicate => "@project='#{project}' and contains(@name,'#{filterstring}')"
    return result.each.map {|x| x.name}
  end

  def users_path
    url_for(action: :users, project: @project)
  end

  def add_path(action)
    url_for(action: action, project: @project, role: params[:role], userid: params[:userid])
  end

  def load_local_packages
    unless @project.api_obj.linkedprojects.empty?
      @localpackages = {}
      prjs = {}
      find_packages_info.each do |p|
        prjs[p[1]] ||= Project.find_by_name(p[1])
        @localpackages[p[0]] = 1 unless prjs[p[1]].is_a? String
      end
    end
  end

  def move_path(direction)
    required_parameters :repository, :path_project, :path_repository
    @project.move_path_in_repository(params[:repository], params[:path_project], params[:path_repository], direction)
    @project.save
    flash[:success] = "Path #{params['path_project']}/#{params['path_repository']} moved successfully"
    redirect_to :action => :repositories, :project => @project
  end

  def set_project
    @project = Project.find_by(name: params[:project])
  end
end
