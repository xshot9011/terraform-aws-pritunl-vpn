#!/bin/bash -x
sudo apt update --yes

sudo tee /etc/apt/sources.list.d/mongodb-org.list << EOF
deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/8.0 multiverse
EOF

sudo tee /etc/apt/sources.list.d/openvpn.list << EOF
deb [ signed-by=/usr/share/keyrings/openvpn-repo.gpg ] https://build.openvpn.net/debian/openvpn/stable jammy main
EOF

sudo tee /etc/apt/sources.list.d/pritunl.list << EOF
deb [ signed-by=/usr/share/keyrings/pritunl.gpg ] https://repo.pritunl.com/stable/apt jammy main
EOF

sudo apt --assume-yes install gnupg
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor --yes
curl -fsSL https://swupdate.openvpn.net/repos/repo-public.gpg | sudo gpg -o /usr/share/keyrings/openvpn-repo.gpg --dearmor --yes
curl -fsSL https://raw.githubusercontent.com/pritunl/pgp/master/pritunl_repo_pub.asc | sudo gpg -o /usr/share/keyrings/pritunl.gpg --dearmor --yes

sudo apt update --yes
sudo apt --assume-yes install pritunl openvpn mongodb-org wireguard wireguard-tools
sudo wget https://github.com/mikefarah/yq/releases/download/v4.2.0/yq_linux_amd64.tar.gz -O - | sudo tar xz && sudo mv yq_linux_amd64 /usr/bin/yq
sudo apt --yes install git binutils rustc cargo pkg-config libssl-dev gettext
sudo git clone https://github.com/aws/efs-utils
cd efs-utils
sudo ./build-deb.sh
sudo apt --yes install ./build/amazon-efs-utils*deb

sudo mkdir -p /mnt/efs
echo "${efs_id}:/ /mnt/efs efs _netdev,noresvport,tls,iam 0 0" | sudo tee -a /etc/fstab
sudo mount -a
sudo chown -R mongodb:mongodb /mnt/efs/

sudo yq e '.storage.dbPath = "/mnt/efs"' -i /etc/mongod.conf
sudo systemctl start mongod pritunl
sudo systemctl status pritunl mongod
sudo systemctl enable mongod pritunl
sudo pritunl set-mongodb mongodb://localhost:27017/pritunl
sudo pritunl set app.redirect_server false
sudo pritunl set app.server_ssl true
sudo pritunl set app.server_port 443
sudo pritunl set app.www_path /usr/share/pritunl/www
sleep 10
sudo systemctl restart pritunl
sudo systemctl status pritunl mongod
sleep 10
sudo systemctl restart pritunl
sudo systemctl status pritunl mongod
sleep 10
sudo lsof -i -P -n | grep -i listen
