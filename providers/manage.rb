USER_IDS = ( 2000..5999 ).to_a
GROUP_IDS = ( 6000..9999 ).to_a

action :manage do
  data_bag_name = (node['authorization']['users']['data_bag'] rescue "users")
  uid_map = ( (node['z']['users']['uids'].to_hash rescue nil) || Hash.new )
  gid_map = ( (node['z']['users']['gids'].to_hash rescue nil) || Hash.new )
  current_uid_map, current_gid_map = Hash.new, Hash.new
  group_users_map = Hash.new(Array.new)

  search(data_bag_name, user_conditional(:manage)) do |u|
    uid = (uid_map[u['id']] || u['uid'] || (USER_IDS - (uid_map.values + current_uid_map.values)).first)
    current_uid_map[u['id']] = uid

    Chef::Log.debug("manage: #{u['id']} (uid:#{uid})")
    Chef::Log.debug("action: #{u['action']}")

    home_path = ( u['home'] ? u['home'] : "/home/#{u['id']}" )
    manage_home = ((home_path != "/dev/null") ? true : false)

    # create our group first
    group u['id'] do
      gid ( u['gid'] || uid )
    end

    # next create our user
    user u['id'] do
      comment u['comment']
      uid uid
      gid ( u['gid'] || uid )
      shell u['shell']
      password u['password'] if u['password']
      supports :manage_home => manage_home
      home home_path
    end

    # build a map of our membership: groups as the key; array of users as value
    Chef::Log.debug("groups(#{u['groups'].inspect})")
    Array(u['groups']).each do |group|
      group_users_map[group] += [ u['id'] ]
    end

    # install ssh related items if needed
    if (home_path != "/dev/null")

      directory "#{home_path}/.ssh" do
        owner uid
        group ( u['gid'] || uid )
        mode "700"
      end

      if u['ssh_config']
        template "#{home_path}/.ssh/config" do
          source "config.erb"
          owner uid
          group ( u['gid'] || uid )
          mode "660"
          variables(:ssh_config => u['ssh_config'])
        end
      end

      if u['ssh_keys']
        template "#{home_path}/.ssh/authorized_keys" do
          source "authorized_keys.erb"
          owner uid
          group ( u['gid'] || uid )
          mode "600"
          variables(:ssh_keys => u['ssh_keys'])
        end
      end

    end
  end

  # now for the magic
  uid_map.merge!(current_uid_map)

  current_users = current_uid_map.keys
  previous_users = uid_map.keys

  # take any action needed for first time user creation
  new_users = (current_users - previous_users)
  new_users.each do |user|
    if !user['password']
      execute "delete password for #{user}" do
        command "passwd -d #{user}"
        action :run
      end
    end
  end

  # take any action needed for auto user removal
  removed_users = (previous_users - current_users)
  removed_users.each do |user|
    uid_map.delete(user)
    user user do
      action :remove
    end

    group user do
      action :remove
    end
  end

  # create needed group_users_map
  Chef::Log.debug("group_users_map(#{group_users_map.inspect})")
  group_users_map.each do |group_name, usernames|
    group_id = (gid_map[group_name] || (GROUP_IDS - (gid_map.values + current_gid_map.values)).first)
    current_gid_map[group_name] = group_id

    group group_name do
      gid group_id
      members usernames
    end
  end

  # rinse repeat magic for groups
  gid_map.merge!(current_gid_map)

  current_groups = current_gid_map.keys
  previous_groups = gid_map.keys

  # take any action needed for auto user removal
  removed_groups = (previous_groups - current_groups)
  removed_groups.each do |g|
    gid_map.delete(g)

    group g do
      action :remove
    end
  end

  # save everything we did
  node.set['z']['users']['uids'] = uid_map
  node.set['z']['users']['gids'] = gid_map

  node.set['z']['users']['users_previous'] = previous_users
  node.set['z']['users']['users_new'] = new_users
  node.set['z']['users']['users_removed'] = removed_users

  node.set['z']['users']['groups_previous'] = previous_groups
  node.set['z']['users']['groups_removed'] = removed_groups
  node.set['z']['users']['group_users_map'] = group_users_map

  # vomit to the log if on debug
  Chef::Log.debug("uid_map:#{uid_map.inspect}")
  Chef::Log.debug("gid_map:#{gid_map.inspect}")
  Chef::Log.debug("previous_users:#{previous_users.inspect}")
  Chef::Log.debug("current_users:#{current_users.inspect}")
  Chef::Log.debug("new_users:#{new_users.inspect}")
  Chef::Log.debug("removed_users:#{removed_users.inspect}")

end

action :remove do
  data_bag_name = (node['authorization']['users']['data_bag'] rescue "users")

  search(data_bag_name, user_conditional(:remove)) do |user|

    uid_map = ( (node['z']['users']['uids'].to_hash rescue nil) || Hash.new )
    Chef::Log.debug("uid_map:#{uid_map.inspect}")
    Chef::Log.debug("remove(#{user['id']})")

    uid_map.delete(user['id'])
    user user['id'] do
      action :remove
    end

    group user['id'] do
      action :remove
    end

    node.set['z']['users']['uids'] = uid_map
    Chef::Log.debug("uid_map:#{uid_map.inspect}")
  end
end

action :destroy do
  data_bag_name = (node['authorization']['users']['data_bag'] rescue "users")

  search(data_bag_name, user_conditional(:destroy)) do |user|

    uid_map = ( (node['z']['users']['uids'].to_hash rescue nil) || Hash.new )
    Chef::Log.debug("uid_map:#{uid_map.inspect}")
    Chef::Log.debug("destroy(#{user['id']})")

    uid_map.delete(user['id'])
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

    node.set['z']['users']['uids'] = uid_map
    Chef::Log.debug("uid_map:#{uid_map.inspect}")
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
