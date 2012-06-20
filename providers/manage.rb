def initialize(*args)
  super
  @action = :manage
end

action :manage do
  data_bag_name = node['users']['data_bag']
  groups = Hash.new(Array.new)
  current_users = Array.new

  search(data_bag_name, user_conditional(:manage)) do |user|
    current_users << user['id']

    home_path = ( user['home'] ? user['home'] : "/home/#{user['id']}" )
    manage_home = ((home_path != "/dev/null") ? true : false)

    Chef::Log.debug("manage_home(#{manage_home})")

    group user['id'] do
      gid ( user['gid'] || user['uid'] )
    end

    user user['id'] do
      comment user['comment']
      uid user['uid']
      gid ( user['gid'] || user['uid'] )
      shell user['shell']
      password user['password'] if user['password']
      supports :manage_home => manage_home
      home home_path
    end

    Chef::Log.debug("groups(#{user['groups'].inspect})")

    Array(user['groups']).each do |group|
      groups[group] += [ user['id'] ]
    end

    if (home_path != "/dev/null")

      directory "#{home_path}/.ssh" do
        owner user['id']
        group ( user['gid'] || user['uid'] )
        mode "700"
      end

      if user['ssh_config']
        template "#{home_path}/.ssh/config" do
          source "config.erb"
          owner user['id']
          group ( user['gid'] || user['uid'] )
          mode "660"
          variables :ssh_config => user['ssh_config']
        end
      end

      if user['ssh_keys']
        template "#{home_path}/.ssh/authorized_keys" do
          source "authorized_keys.erb"
          owner user['id']
          group ( user['gid'] || user['uid'] )
          mode "600"
          variables :ssh_keys => user['ssh_keys']
        end
      end

    end
  end

  previous_users = ( node['chef_users'] || current_users )
  removed_users = (previous_users - current_users)
  removed_users.each do |user|
    user user do
      action :remove
    end

    group user do
      action :remove
    end
  end
  node.set['chef_users'] = current_users

  Chef::Log.debug("current_users:#{current_users.inspect}")
  Chef::Log.debug("previous_users:#{previous_users.inspect}")
  Chef::Log.debug("removed_users:#{removed_users.inspect}")
  Chef::Log.debug("node.set['chef_users']:#{node['chef_users'].inspect}")

  Chef::Log.debug("groups(#{groups.inspect})")
  groups.each do |group_name, member_names|
    group_id = ( node['next_gid'] || 7000 )
    node.set['next_gid'] = ( group_id + 1)

    group group_name do
      gid group_id
      members member_names
    end
  end

end

action :remove do
  data_bag_name = node['users']['data_bag']

  search(data_bag_name, user_conditional(:remove)) do |user|

    user user['id'] do
      action :remove
    end

    group user['id'] do
      action :remove
    end

  end
end

action :destroy do
  data_bag_name = node['users']['data_bag']

  search(data_bag_name, user_conditional(:destroy)) do |user|

    user user['id'] do
      action :remove
    end

    group user['id'] do
      action :remove
    end

    home_path = ( user['home'] ? user['home'] : "/home/#{user['id']}" )
    manage_home = ((home_path != "/dev/null") ? true : false)
    return true if !manage_home

    directory home_path do
      recursive true
      action :delete
    end

  end
end

private

def user_conditional(action=:manage)
  authorized_users = node['authorization']['users']
  authorized_groups = node['authorization']['groups']

  tmp_conditional, user_conditional, group_conditional = Array.new, Array.new, Array.new

  if (authorized_users.count > 0)
    authorized_users.each do |authorized_user|
      user_conditional << "id:#{authorized_user}"
    end
    Chef::Log.debug("user_conditional(#{user_conditional.inspect})")
    tmp = user_conditional.join(" OR ")
    tmp_conditional << ((user_conditional.count > 1) ? "(#{tmp})" : tmp)
  end

  if (authorized_groups.count > 0)
    authorized_groups.each do |authorized_group|
      group_conditional << "groups:#{authorized_group}"
    end
    Chef::Log.debug("group_conditional(#{group_conditional.inspect})")
    tmp = group_conditional.join(" OR ")
    tmp_conditional << ((group_conditional.count > 1) ? "(#{tmp})" : tmp)
  end

  tmp_conditional = tmp_conditional.flatten.compact
  tmp = tmp_conditional.join(" AND ")
  conditional = ((tmp_conditional.count > 1) ? "(#{tmp})" : tmp)

  conditional += case action
  when :manage
    " NOT action:remove NOT action:destroy"
  when :remove
    " AND action:remove"
  when :destroy
    " AND action:destroy"
  end

  Chef::Log.debug("conditional(#{conditional.inspect})")

  conditional
end
