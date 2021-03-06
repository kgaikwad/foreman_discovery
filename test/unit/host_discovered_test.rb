require 'test_plugin_helper'

class HostDiscoveredTest < ActiveSupport::TestCase
  include FactImporterIsolation
  allow_transactions_for_any_importer

  setup do
    @facts = parse_json_fixture('/facts.json')['facts']
    set_default_settings
  end

  test "should be able to create Host::Discovered objects" do
    host = Host.create :name => "mydiscoveredhost", :type => "Host::Discovered"
    assert host.is_a?(Host::Discovered)
  end

  test "should import facts from yaml as Host::Discovered" do
    assert discover_host_from_facts(@facts)
    assert Host::Discovered.find_by_name('mace41f13cc3658')
  end

  test 'fact value association is set accordingly' do
    discovered_host = FactoryBot.create(:discovered_host, :with_facts, :fact_count => 1)
    fact_value = discovered_host.fact_values.first
    assert_equal discovered_host.id, fact_value.host.id
  end

  test "should setup subnet" do
    subnet = FactoryBot.create(:subnet_ipv4, :name => 'Subnet99', :network => '10.35.27.0', :organizations => [organization_one], :locations => [location_one])
    Subnet.expects(:subnet_for).with('10.35.27.3').returns(subnet)
    host = discover_host_from_facts(@facts)
    assert_equal subnet, host.primary_interface.subnet
  end

  test "should setup subnet with org and loc set via settings" do
    org = FactoryBot.create(:organization, :name => "subnet_org")
    loc = FactoryBot.create(:location, :name => "subnet_loc")
    Setting['discovery_organization'] = org.name
    Setting['discovery_location'] = loc.name
    subnet = FactoryBot.create(:subnet_ipv4, :name => 'Subnet99', :network => '10.35.27.0', :organizations => [org], :locations => [loc])
    Subnet.expects(:subnet_for).with('10.35.27.3').returns(subnet)
    host = discover_host_from_facts(@facts)
    assert_equal subnet, host.primary_interface.subnet
  end

  test "should setup subnet with org and loc set via facts" do
    org = FactoryBot.create(:organization, :name => "subnet_org_via_fact")
    loc = FactoryBot.create(:location, :name => "subnet_loc_via_fact")
    @facts['foreman_organization'] = org.name
    @facts['foreman_location'] = loc.name
    subnet = FactoryBot.create(:subnet_ipv4, :name => 'Subnet99', :network => '10.35.27.0', :organizations => [org], :locations => [loc])
    Subnet.expects(:subnet_for).with('10.35.27.3').returns(subnet)
    host = discover_host_from_facts(@facts)
    assert_equal subnet, host.primary_interface.subnet
  end

  test "should set nested org and loc" do
    org_parent = FactoryBot.create(:organization, :name => "org")
    org = FactoryBot.create(:organization, :name => "suborg", :parent_id => org_parent.id)
    loc_parent = FactoryBot.create(:location, :name => "loc")
    loc = FactoryBot.create(:location, :name => "subloc", :parent_id => loc_parent.id)
    Setting['discovery_organization'] = org.name
    Setting['discovery_location'] = loc.name
    subnet = FactoryBot.create(:subnet_ipv4, :name => 'Subnet99', :network => '10.35.27.0', :organizations => [org], :locations => [loc])
    Subnet.expects(:subnet_for).with('10.35.27.3').returns(subnet)
    host = discover_host_from_facts(@facts)
    assert_equal org, host.organization
    assert_equal loc, host.location
  end

  test "should raise when fact_name setting isn't present" do
    Setting[:discovery_fact] = 'macaddress_foo'
    exception = assert_raises(::Foreman::Exception) do
      discover_host_from_facts(@facts)
    end
    assert_match(/Expected discovery_fact '\w+' is missing/, exception.message)
  end

  test "should be able to refresh facts" do
    host = Host.create :name => "mydiscoveredhost", :ip => "1.2.3.4", :type => "Host::Discovered"
    ::ForemanDiscovery::NodeAPI::Inventory.any_instance.stubs(:facter).returns(@facts)
    assert host.refresh_facts
  end

  test "should create discovered host with hostname if a fact was supplied" do
    Setting[:discovery_hostname] = 'somefact'
    facts = @facts.merge({"somefact" => "somename"})
    host = discover_host_from_facts(facts)
    assert_equal 'macsomename', host.name
    refute_equal 'e4:1f:13:cc:36:5a', host.mac
  end

  test "should lock host into discovery via PXE configuration" do
    Host::Discovered.delete('mace41f13cc3658')
    Setting[:discovery_lock] = "true"
    subnet = FactoryBot.create(:subnet,
                                :tftp,
                                :network => '10.35.27.0',
                                :cidr    => '24',
                                :mask    => '255.255.255.0',
                                :organizations => [organization_one],
                                :locations => [location_one]
    )
    Subnet.expects(:subnet_for).with('10.35.27.3').returns(subnet)
    ProxyAPI::TFTP.any_instance.expects(:set).with(anything, 'e4:1f:13:cc:36:58', anything).returns(true).times(3)
    TemplateKind::PXE.each do |kind|
      ProvisioningTemplate.where(:name => "#{kind.downcase}_discovery").first_or_create(
          :template_kind_id => template_kinds(kind.downcase.to_sym),
          :snippet => true,
          :template => "test"
      )
    end
    assert discover_host_from_facts(@facts)
    assert Host::Discovered.find_by_name('mace41f13cc3658')
    refute Host::Managed.find_by_name('mace41f13cc3658')
  end

  test "should create discovered host with fact_name as a name if it is a valid mac" do
    Setting[:discovery_fact] = 'somefact'
    Setting[:discovery_hostname] = 'somefact'
    facts = @facts.merge({"somefact" => "E4:1F:13:CC:36:5A"})
    host = discover_host_from_facts(facts)
    assert_equal 'mace41f13cc365a', host.name
    assert_equal 'e4:1f:13:cc:36:5a', host.mac
  end

  test "should create discovered host with default name if fact_name isn't a valid mac" do
    Setting[:discovery_fact] = 'lsbdistcodename'
    exception = assert_raises(::Foreman::Exception) do
      discover_host_from_facts(@facts)
    end
    assert_match(/Unable to detect primary interface using MAC/, exception.message)
  end

  test "should not create discovered host when managed host exists" do
    FactoryBot.create(:host, :mac => 'E4:1F:13:CC:36:58')
    exception = assert_raises(::Foreman::Exception) do
      discover_host_from_facts(@facts)
    end
    assert_match(/Host already exists as managed/, exception.message)
  end

  test "should create discovered host with prefix" do
    Setting[:discovery_prefix] = 'test'
    host = discover_host_from_facts(@facts)
    assert_equal 'teste41f13cc3658', host.name
  end

  test "should create discovered host without prefix" do
    Setting[:discovery_prefix] = ''
    host = discover_host_from_facts(@facts)
    assert_equal 'e41f13cc3658',host.name
  end

  test "should refresh existing discovered" do
    interface = mock()
    interface.stubs(:host).returns(Host.create(:name => "xyz", :type => "Host::Discovered"))
    ::Nic::Managed.stubs(:where).with(:mac => @facts['discovery_bootif'].downcase, :primary => true).returns([interface])
    host = discover_host_from_facts(@facts)
    assert_equal 'xyz', host.name
  end

  test "should raise when hostname fact cannot be found" do
    Setting[:discovery_hostname] = 'macaddress_foo'
    exception = assert_raises(::Foreman::Exception) do
      discover_host_from_facts(@facts)
    end
    assert_match(/Invalid facts: hash does not contain a valid value for any of the facts in the discovery_hostname setting:/, exception.message)
  end

  test "should raise when hostname cannot be computed due to normlization and no prefix" do
    @facts['invalidhostnamefact'] = '...'
    Setting[:discovery_hostname] = 'invalidhostnamefact'
    Setting[:discovery_prefix] = ''
    exception = assert_raises(::Foreman::Exception) do
      discover_host_from_facts(@facts)
    end
    assert_match(/Invalid hostname: Could not normalize the hostname/, exception.message)
  end

  test 'discovered host can be searched in multiple taxonomies' do
    org1 = FactoryBot.create(:organization)
    org2 = FactoryBot.create(:organization)
    org3 = FactoryBot.create(:organization)
    user_subset = FactoryBot.create(:user, :organizations => [org1, org2])
    user_all = FactoryBot.create(:user, :organizations => [org1, org2, org3])
    host1 = FactoryBot.create(:host, :type => "Host::Discovered", :organization => org1)
    host2 = FactoryBot.create(:host, :type => "Host::Discovered", :organization => org2)
    host3 = FactoryBot.create(:host, :type => "Host::Discovered", :organization => org3)
    hosts = nil

    assert_nil Organization.current
    as_user(user_subset) do
      hosts = Host::Discovered.all
    end
    assert_includes hosts, host1
    assert_includes hosts, host2
    refute_includes hosts, host3

    as_user(user_all) do
      hosts = Host::Discovered.all
    end
    assert_includes hosts, host1
    assert_includes hosts, host2
    assert_includes hosts, host3
  end

  test "provisioning a discovered host without saving it doesn't create a token" do
    Setting[:token_duration] = 30 #enable tokens so that we only test the CR
    Setting[:discovery_prefix] = '123'
    host = discover_host_from_facts(@facts)
    host.save
    h = ::ForemanDiscovery::HostConverter.to_managed(host)
    refute_valid h
    assert Token.where(:host_id => h.id).empty?
  end

  test "all non-discovery facts are deleted after managed conversion" do
    Setting[:discovery_clean_facts] = true
    raw = parse_json_fixture('/facts.json')['facts']
    raw.merge!({
      'delete_me' => "content",
      'discovery_keep_me' => "content",
      })
    host = discover_host_from_facts(raw)
    host.save
    managed = ::ForemanDiscovery::HostConverter.to_managed(host)
    managed.clear_facts
    assert_nil managed.facts_hash['delete_me']
    assert_equal "content", managed.facts_hash['discovery_keep_me']
  end

  test "primary interface is preserved after managed conversion" do
    raw = parse_json_fixture('/facts.json')['facts']
    raw.merge!({
      'keep_me' => "content",
      'discovery_keep_me' => "content",
      })
    host = discover_host_from_facts(raw)
    host.save
    managed = ::ForemanDiscovery::HostConverter.to_managed(host)
    refute_nil managed.primary_interface
    assert_equal "e4:1f:13:cc:36:58", managed.primary_interface.mac
  end

  test "provision interface is preserved after managed conversion" do
    raw = parse_json_fixture('/facts.json')['facts']
    raw.merge!({
      'keep_me' => "content",
      'discovery_keep_me' => "content",
      })
    host = discover_host_from_facts(raw)
    host.save
    managed = ::ForemanDiscovery::HostConverter.to_managed(host)
    refute_nil managed.provision_interface
    assert_equal "e4:1f:13:cc:36:58", managed.provision_interface.mac
  end

  test "provision interface host association is preserved after managed conversion" do
    raw = parse_json_fixture('/facts.json')['facts']
    raw.merge!({
      'keep_me' => "content",
      'discovery_keep_me' => "content",
      })
    host = discover_host_from_facts(raw)
    host.save
    managed = ::ForemanDiscovery::HostConverter.to_managed(host)
    refute_nil managed.provision_interface
    assert_equal host, managed.provision_interface.host
  end

  test "all facts are preserved after managed conversion" do
    raw = parse_json_fixture('/facts.json')['facts']
    raw.merge!({
      'keep_me' => "content",
      'discovery_keep_me' => "content",
      })
    host = discover_host_from_facts(raw)
    host.save
    managed = ::ForemanDiscovery::HostConverter.to_managed(host)
    managed.clear_facts
    assert_equal "content", managed.facts_hash['keep_me']
    assert_equal "content", managed.facts_hash['discovery_keep_me']
  end

  test "normalization of MAC into a discovered host hostname" do
    assert_equal Host::Discovered.normalize_string_for_hostname("90:B1:1C:54:D5:82"),"90b11c54d582"
  end

  test "normalization of a string containing multiple non-alphabetical characters" do
    assert_equal Host::Discovered.normalize_string_for_hostname(".-_Test::Host.name_-."),"testhostname"
  end

  test "normalization of a valid hostname" do
    assert_equal Host::Discovered.normalize_string_for_hostname("testhostname"),"testhostname"
  end

  test "empty string after hostname normalization should raise an error" do
    exception = assert_raises(::Foreman::Exception) do
      Host::Discovered.normalize_string_for_hostname(".-_")
    end
    assert_match(/Invalid hostname: Could not normalize the hostname/, exception.message)
  end

  test "chooshing the first valid fact from array of fact names" do
    facts = {"custom_hostname" => "testhostname","notmyfact" => "notusedfactvalue"}
    discovery_hostname_fact_array = ['macaddress','custom_hostname','someotherfact']
    assert_equal Host::Discovered.return_first_valid_fact(discovery_hostname_fact_array,facts),"testhostname"
  end

  context 'notification recipients' do
    setup do
      @admins = User.except_hidden.where(:admin => true).pluck(:id)
      @org = FactoryBot.create(:organization)
      @host = FactoryBot.create(:discovered_host)
    end

    test 'finds admin users' do
      assert_equal @admins.sort, @host.notification_recipients_ids.sort
    end

    test 'finds users who can create_host in the host org' do
      setup_user 'create', 'hosts'
      User.current.organizations << @org
      recipients = [User.current.id, @admins].flatten.sort
      @host.organization = @org
      assert_equal recipients, @host.notification_recipients_ids.sort
    end

    test 'finds only admin users if organizations are disabled' do
      begin
        SETTINGS[:organizations_enabled] = false
        assert_equal @admins.sort, @host.notification_recipients_ids.sort
      ensure
        SETTINGS[:organizations_enabled] = true
      end
    end
  end

  def parse_json_fixture(relative_path)
    return JSON.parse(File.read(File.expand_path(File.dirname(__FILE__) + relative_path)))
  end
end
