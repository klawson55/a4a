#
# Cookbook:: a4a
# Recipe:: default
#
# Kevin Lawson 20180410

yum_repository 'epel' do
  description "Extra Packages for Enterprise Linux 7"
  baseurl "http://download.fedoraproject.org/pub/epel/7/$basearch"
  gpgcheck false
	action :create
end

package 'nginx' do
  action :install
end

service 'nginx' do
  action [ :enable, :start ]
end

web_dir = "/var/www/html"

directory web_dir do
  recursive true
end

cookbook_file "/var/www/html/index.html" do
  source "index.html"
  mode "0644"
end

template "/etc/nginx/nginx.conf" do   
  source "nginx.conf.erb"
  notifies :reload, "service[nginx]"
end

bash 'insertIP' do
  code <<-EOH
	export myIP=$(hostname -I | awk '{print $1}')
	sed -i "s/IPADDRESS/${myIP}/g" /var/www/html/index.html
	EOH
end
