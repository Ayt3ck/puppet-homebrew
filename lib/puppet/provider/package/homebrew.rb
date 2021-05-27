require 'puppet/provider/package'

Puppet::Type.type(:package).provide(:homebrew, :parent => Puppet::Provider::Package) do
  desc 'Package management using HomeBrew (+ casks!) on OSX'

  confine :operatingsystem => :darwin

  has_feature :installable
  has_feature :uninstallable
  has_feature :upgradeable
  has_feature :versionable

  has_feature :install_options

  commands :brew => '/usr/local/bin/brew'
  commands :stat => '/usr/bin/stat'

  def self.execute(cmd, failonfail = false, combine = false)
    owner = stat('-nf', '%Uu', '/usr/local/bin/brew').to_i
    group = stat('-nf', '%Ug', '/usr/local/bin/brew').to_i
    home  = Etc.getpwuid(owner).dir

    if owner == 0
      raise Puppet::ExecutionFailure, 'Homebrew does not support installations owned by the "root" user. Please check the permissions of /usr/local/bin/brew'
    end

    # the uid and gid can only be set if running as root
    if Process.uid == 0
      uid = owner
      gid = group
    else
      uid = nil
      gid = nil
    end

    if Puppet.features.bundled_environment?
      Bundler.with_clean_env do
        super(cmd, :uid => uid, :gid => gid, :combine => combine,
              :custom_environment => { 'HOME' => home }, :failonfail => failonfail)
      end
    else
      super(cmd, :uid => uid, :gid => gid, :combine => combine,
            :custom_environment => { 'HOME' => home }, :failonfail => failonfail)
    end
  end

  def self.instances(justme = false)
    package_list.collect { |hash| new(hash) }
  end

  def execute(*args)
    # This does not return exit codes in puppet <3.4.0
    # See https://projects.puppetlabs.com/issues/2538
    self.class.execute(*args)
  end

  def fix_checksum(files)
    begin
      for file in files
        File.delete(file)
      end
    rescue Errno::ENOENT
      Puppet.warning "Could not remove mismatched checksum files #{files}"
    end

    raise Puppet::ExecutionFailure, "Checksum error for package #{name} in files #{files}"
  end

  def resource_name
    if @resource[:name].match(/^https?:\/\//)
      @resource[:name]
    else
      @resource[:name].downcase
    end
  end

  def install_name
    should = @resource[:ensure].downcase

    case should
    when true, false, Symbol
      resource_name
    else
      "#{resource_name}@#{should}"
    end
  end

  def install_options
    Array(resource[:install_options]).flatten.compact
  end

  def latest
    begin
      Puppet.debug "Querying latest for #{resource_name} package..."
      output = execute([command(:brew), :info, resource_name], :failonfail => true)

      output.each_line do |line|
        line.chomp!
        next if line.empty?
        next if line !~ /#{@resource[:name]}:\s(.*)/i
        Puppet.debug "  Latest versions for #{resource_name}: #{$1}"
        versions = $1
        return $1 if versions =~ /stable (\d+[^\s]*)\s+\(bottled\)/
        return $1 if versions =~ /stable (\d+.*), HEAD/
        return $1 if versions =~ /stable (\d+.*)/
        return $1 if versions =~ /(\d+.*)\s+\(auto_updates\)/
        return $1 if versions =~ /(\d+.*)/
      end
      nil
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not query latest version of package: #{detail}"
    end
  end

  def query
    self.class.package_list(:justme => resource_name)
  end

  def install
    begin
      Puppet.debug "Package #{install_name} found, installing..."
      output = execute([command(:brew), :install, install_name, *install_options], :failonfail => true)

      if output =~ /sha256 checksum/
        Puppet.debug "Fixing checksum error..."
        mismatched = output.match(/Already downloaded: (.*)/).captures
        fix_checksum(mismatched)
      end
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not install package: #{detail}"
    end
  end

  def uninstall
    begin
      Puppet.debug "Uninstalling #{resource_name}"
      execute([command(:brew), :uninstall, resource_name], :failonfail => true)
    rescue Puppet::ExecutionFailure => detail
        raise Puppet::Error, "Could not uninstall package: #{detail}"
    end
  end

  def update
    if installed?
      begin
        Puppet.debug "Package #{resource_name} found, upgrading..."
        output = execute([command(:brew), :upgrade, install_name, *install_options], :failonfail => true)

        if output =~ /sha256 checksum/
          Puppet.debug "Fixing checksum error..."
          mismatched = output.match(/Already downloaded: (.*)/).captures
          fix_checksum(mismatched)
        end
      rescue Puppet::ExecutionFailure => detail
        raise Puppet::Error, "Could not upgrade package: #{detail}"
      end

    else
      install
    end
  end

  def installed?
    begin
      Puppet.debug "Check if #{resource_name} package installed"
      is_not_installed = execute([command(:brew), :info, install_name]).split("\n").grep(/^Not installed$/).first
    rescue Puppet::ExecutionFailure
        raise Puppet::Error, "Could not get status package: #{detail}"
    end
    is_not_installed.nil?
  end

  def self.package_list(options={})
    Puppet.debug "Listing installed packages"
    begin
      if resource_name = options[:justme]
        result = execute([command(:brew), :list, '--versions', resource_name])
        unless result.include? resource_name
          result += execute([command(:brew), :list, '--cask', '--versions', resource_name])
        end
        if result.empty?
          Puppet.debug "Package #{resource_name} not installed"
        else
          Puppet.debug "Found package #{result}"
        end
      else
        result = execute([command(:brew), :list, '--versions'])
        result += execute([command(:brew), :list, '--cask', '--versions'])
      end
      list = result.lines.map {|line| name_version_split(line)}
    rescue Puppet::ExecutionFailure => detail
      raise Puppet::Error, "Could not list packages: #{detail}"
    end

    if options[:justme]
      return list.shift
    else
      return list
    end
  end

  def self.name_version_split(line)
    if line =~ (/^(\S+)\s+(.+)/)
      {
        :name     => $1,
        :ensure   => $2,
        :provider => :homebrew
      }
    else
      Puppet.warning "Could not match #{line}"
      nil
    end
  end
end
