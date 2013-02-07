USER_IDS  = (2000..5999).to_a
GROUP_IDS = (6000..9999).to_a

################################################################################

action :manage do
  data_bag_name = (node['authorization']['users']['data_bag'] rescue "users")

  taken_uids = (node.etc.passwd.collect{ |z| z[1]['uid'] } rescue Array.new)
  processed_uids = Array.new
  Chef::Log.info("taken_uids(#{taken_uids.inspect})")

  taken_gids = (node.etc.group.collect{ |z| z[1]['gid'] } rescue Array.new)
  processed_gids = Array.new
  Chef::Log.info("taken_gids(#{taken_gids.inspect})")

  group_users_map = Hash.new(Array.new)

  search(data_bag_name, user_conditional(:manage)) do |u|
    next if taken_uids.count == 0

    next_uid = (USER_IDS - (processed_uids + taken_uids).flatten).first

    existing_user_id = (node['etc']['passwd'][u['id']]['uid'] rescue nil)
    user_id = (existing_user_id || u['uid'] || next_uid)
    processed_uids << user_id

    existing_user_group_id = (node['etc']['passwd'][u['id']]['gid'] rescue nil)
    user_group_id = (existing_user_group_id || u['gid'] || user_id)

    Chef::Log.info("manage: #{u['id']} (uid:#{user_id}, existing:#{existing_user_id}, next:#{next_uid})")

    home_path = ( u['home'] ? u['home'] : "/home/#{u['id']}" )
    manage_home = ((home_path != "/dev/null") ? true : false)

    # create our group first
    group u['id'] do
      gid user_group_id
    end

    # next create our user
    user u['id'] do
      comment u['comment']
      uid user_id
      gid user_group_id
      shell u['shell']
      password u['password'] if u['password']
      supports :manage_home => manage_home
      home home_path
    end

    # build a map of our membership: groups as the key; array of users as value
    Chef::Log.info("groups(#{u['groups'].inspect})")
    Array(u['groups']).each do |group|
      group_users_map.merge!(group => [u['id']]){ |k,o,n| k = (o + n) }
    end

    # install ssh related items if needed
    if (home_path != "/dev/null")

      directory home_path do
        owner user_id
        group user_group_id
        mode "700"
      end

      directory "#{home_path}/.ssh" do
        owner user_id
        group user_group_id
        mode "700"
      end

      if u['ssh_config']
        template "#{home_path}/.ssh/config" do
          source "config.erb"
          owner user_id
          group user_group_id
          mode "660"
          variables(:ssh_config => u['ssh_config'])
        end
      end

      if u['ssh_keys']
        template "#{home_path}/.ssh/authorized_keys" do
          source "authorized_keys.erb"
          owner user_id
          group user_group_id
          mode "600"
          variables(:ssh_keys => u['ssh_keys'])
        end
      end

    end
  end

  # take any action needed for first time user creation
  # new_users = (current_users - previous_users)
  # new_users.each do |user|
  #   if !user['password']
  #     execute "delete password for #{user}" do
  #       command "passwd -d #{user}"
  #       action :run
  #       only_if { %x( /usr/bin/chage -l #{user} | grep "password must be changed" ) }
  #     end
  #     execute "setup password expiration for #{user}" do
  #       command "chage --lastday 0 --expiredate -1 --inactive -1 --mindays 0 --maxdays 99999 --warndays 7 #{user}"
  #       action :run
  #       only_if { %x( /usr/bin/chage -l #{user} | grep "password must be changed" ) }
  #     end
  #   end
  # end

  # create needed group_users_map
  Chef::Log.info("group_users_map(#{group_users_map.inspect})")
  group_users_map.each do |group_name, usernames|
    next if taken_uids.count == 0

    next_gid = (GROUP_IDS - (processed_gids + taken_gids).flatten).first

    existing_group_id = (node['etc']['group'][group_name]['gid'] rescue nil)
    group_id = (existing_group_id || next_gid)
    processed_gids << group_id

    group group_name do
      gid group_id
      members usernames
    end
  end
end

################################################################################

action :remove do
  data_bag_name = (node['authorization']['users']['data_bag'] rescue "users")

  search(data_bag_name, user_conditional(:remove)) do |user|
    Chef::Log.info("remove(#{user['id']})")

    user user['id'] do
      action :remove
    end

    group user['id'] do
      action :remove
    end
  end
end

################################################################################

action :destroy do
  data_bag_name = (node['authorization']['users']['data_bag'] rescue "users")

  search(data_bag_name, user_conditional(:destroy)) do |user|
    Chef::Log.info("destroy(#{user['id']})")

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

################################################################################
private
################################################################################

def user_conditional(action=:manage)

  Chef::Log.info("user_conditional(#{action})")

  if (action == :remove)
    return "action:remove"
  elsif (action == :destroy)
    return "action:destroy"
  end

  authorized_users = node['authorization']['users']
  authorized_groups = node['authorization']['groups']

  Chef::Log.info("authorized_users(#{authorized_users.inspect})")
  Chef::Log.info("authorized_groups(#{authorized_groups.inspect})")

  tmp_conditional, user_conditional, group_conditional = Array.new, Array.new, Array.new

  if (authorized_users.count > 0)
    authorized_users.each do |authorized_user|
      user_conditional << "id:#{authorized_user}"
    end
    Chef::Log.info("user_conditional(#{user_conditional.inspect})")
    tmp = user_conditional.join(" OR ")
    tmp_conditional << ((user_conditional.count > 1) ? "(#{tmp})" : tmp)
  end

  if (authorized_groups.count > 0)
    authorized_groups.each do |authorized_group|
      group_conditional << "groups:#{authorized_group}"
    end
    Chef::Log.info("group_conditional(#{group_conditional.inspect})")
    tmp = group_conditional.join(" OR ")
    tmp_conditional << ((group_conditional.count > 1) ? "(#{tmp})" : tmp)
  end

  tmp_conditional = tmp_conditional.flatten.compact
  tmp = tmp_conditional.join(" AND ")
  conditional = ((tmp_conditional.count > 1) ? "(#{tmp})" : tmp)

  conditional += " AND action:manage"

  Chef::Log.info("conditional(#{conditional.inspect})")
  conditional
end
