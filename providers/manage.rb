action :manage do
  data_bag_name = node['users']['data_bag']
  groups = Hash.new(Array.new)
  current_users = Array.new

  search(data_bag_name, user_conditional(:manage)) do |u|
    current_users << u['id']

    Chef::Log.debug("manage: #{u['id']}")
    Chef::Log.debug("action: #{u['action']}")

    home_path = ( u['home'] ? u['home'] : "/home/#{u['id']}" )
    manage_home = ((home_path != "/dev/null") ? true : false)


    group u['id'] do
      gid ( u['gid'] || u['uid'] )
    end

    user u['id'] do
      comment u['comment']
      uid u['uid']
      gid ( u['gid'] || u['uid'] )
      shell u['shell']
      password u['password'] if u['password']
      supports :manage_home => manage_home
      home home_path
    end

    Chef::Log.debug("groups(#{u['groups'].inspect})")
    Array(u['groups']).each do |group|
      groups[group] += [ u['id'] ]
    end

    if (home_path != "/dev/null")

      directory "#{home_path}/.ssh" do
        owner u['id']
        group ( u['gid'] || u['uid'] )
        mode "700"
      end

      if u['ssh_config']
        template "#{home_path}/.ssh/config" do
          source "config.erb"
          owner u['id']
          group ( u['gid'] || u['uid'] )
          mode "660"
          variables :ssh_config => u['ssh_config']
        end
      end

      if u['ssh_keys']
        template "#{home_path}/.ssh/authorized_keys" do
          source "authorized_keys.erb"
          owner u['id']
          group ( u['gid'] || u['uid'] )
          mode "600"
          variables :ssh_keys => u['ssh_keys']
        end
      end

    end
  end

  previous_users = ( (node['jovelabs']['users']['current'] rescue nil) || current_users )

  new_users = (current_users - previous_users)
  new_users.each do |user|
    if !user['password']
      execute "delete password for #{user}" do
        command "passwd -d #{user}"
        action :run
      end
    end
  end

  removed_users = (previous_users - current_users)
  removed_users.each do |user|
    user user do
      action :remove
    end

    group user do
      action :remove
    end
  end

  node.set['jovelabs']['users']['previous'] = previous_users
  node.set['jovelabs']['users']['current'] = current_users
  node.set['jovelabs']['users']['new'] = new_users
  node.set['jovelabs']['users']['removed'] = removed_users

  Chef::Log.debug("previous_users:#{previous_users.inspect}")
  Chef::Log.debug("current_users:#{current_users.inspect}")
  Chef::Log.debug("new_users:#{new_users.inspect}")
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

    Chef::Log.debug("remove(#{user['id']})")

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

    Chef::Log.debug("destroy(#{user['id']})")

    user user['id'] do
      action :remove
    end

    group user['id'] do
      action :remove
    end

    home_path = ( user['home'] ? user['home'] : "/home/#{user['id']}" )
    manage_home = ((home_path != "/dev/null") ? true : false)
    next if !manage_home

    directory home_path do
      recursive true
      action :delete
    end

  end
end

private

def user_conditional(action=:manage)

  Chef::Log.debug("user_conditional(#{action})")

  if (action == :remove)
    return "action:remove"
  elsif (action == :destroy)
    return "action:destroy"
  end

  authorized_users = node['authorization']['users']
  authorized_groups = node['authorization']['groups']

  Chef::Log.debug("authorized_users.count == #{authorized_users.count}")
  Chef::Log.debug("authorized_groups.count == #{authorized_groups.count}")

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

  conditional += " AND action:manage"

  Chef::Log.debug("conditional(#{conditional.inspect})")
  conditional
end
