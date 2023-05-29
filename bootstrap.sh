#!/bin/bash -uxe
# A bash script that prepares the OS
# before running the Ansible playbook

ANSIBLE_PROJECT="bootstrap-server"
GIT_REPO="https://github.com/mogmix/bootstrap-server"

# Discard stdin. Needed when running from an one-liner which includes a newline
read -N 999999 -t 0.001

# Quit on error
set -e

check_root() {
  # Check if the user is root or not
  if [[ $EUID -ne 0 ]]; then
    if [[ ! -z "$1" ]]; then
      SUDO='sudo -E -H'
    else
      SUDO='sudo -E'
    fi
  else
    SUDO=''
  fi
}

install_dependencies() {
  REQUIRED_PACKAGES=(
    sudo
    software-properties-common
    dnsutils
    curl
    git
    locales
    rsync
    apparmor
    python3
    python3-setuptools
    python3-apt
    python3-venv
    python3-pip
    aptitude
    direnv
  )

  REQUIRED_PACKAGES_ARM64=(
    gcc
    python3-dev
    libffi-dev
    libssl-dev
    make
  )

  check_root
  # Disable interactive apt functionality
  export DEBIAN_FRONTEND=noninteractive
  # Update apt database, update all packages and install Ansible + dependencies
  $SUDO apt update -y
  yes | $SUDO apt-get -o Dpkg::Options::="--force-confold" -fuy dist-upgrade
  yes | $SUDO apt-get -o Dpkg::Options::="--force-confold" -fuy install "${REQUIRED_PACKAGES[@]}"
  yes | $SUDO apt-get -o Dpkg::Options::="--force-confold" -fuy autoremove
  [ $(uname -m) == "aarch64" ] && yes | $SUDO apt install -fuy "${REQUIRED_PACKAGES_ARM64[@]}"
  export DEBIAN_FRONTEND=
}

# Install all the dependencies
install_dependencies

# Clone the Ansible playbook
if [ -d "$HOME/$ANSIBLE_PROJECT" ]; then
  pushd $HOME/$ANSIBLE_PROJECT
  git pull
  popd
else
  git clone $GIT_REPO $HOME/$ANSIBLE_PROJECT
fi

# Set up a Python venv
set +e
if which python3.9; then
  PYTHON=$(which python3.9)
else
  PYTHON=$(which python3)
fi
set -e
cd $HOME/$ANSIBLE_PROJECT
[ -d $HOME/$ANSIBLE_PROJECT/.venv ] || $PYTHON -m venv .venv
export VIRTUAL_ENV="$HOME/$ANSIBLE_PROJECT/.venv"
export PATH="$HOME/$ANSIBLE_PROJECT/.venv/bin:$PATH"
.venv/bin/python3 -m pip install --upgrade pip
.venv/bin/python3 -m pip install -r requirements.txt

# Install the Galaxy requirements
cd $HOME/$ANSIBLE_PROJECT && ansible-galaxy install --force -r requirements.yml

touch $HOME/$ANSIBLE_PROJECT/custom.yml

custom_filled=$(awk -v RS="" '/username/{print FILENAME}' $HOME/$ANSIBLE_PROJECT/custom.yml)

if [[ "$custom_filled" =~ "custom.yml" ]]; then
  clear
  echo "custom.yml already exists. Running the playbook..."
  echo
  echo "If you want to change something (e.g. username, domain name, etc.)"
  echo "Please edit custom.yml or secret.yml manually, and then re-run this script"
  echo
  cd $HOME/$ANSIBLE_PROJECT && ansible-playbook --ask-vault-pass run.yml
  exit 0
fi

echo "ansible_project: $ANSIBLE_PROJECT" >$HOME/$ANSIBLE_PROJECT/custom.yml

clear
echo "Welcome to $ANSIBLE_PROJECT!"
echo
echo "This script is interactive"
echo "If you prefer to fill in the custom.yml file manually,"
echo "press [Ctrl+C] to quit this script"
echo
echo "Enter your desired UNIX username"
read -p "Username: " username
until [[ "$username" =~ ^[a-z0-9]*$ ]]; do
  echo "Invalid username"
  echo "Make sure the username only contains lowercase letters and numbers"
  read -p "Username: " username
done

echo "username: \"${username}\"" >>$HOME/$ANSIBLE_PROJECT/custom.yml

echo
echo "Enter your user password"
echo "This password will be used for Authelia login, administrative access and SSH login"
read -s -p "Password: " user_password
until [[ "${#user_password}" -lt 60 ]]; do
  echo
  echo "The password is too long"
  echo "OpenSSH does not support passwords longer than 72 characters"
  read -s -p "Password: " user_password
done
echo
read -s -p "Repeat password: " user_password2
echo
until [[ "$user_password" == "$user_password2" ]]; do
  echo
  echo "The passwords don't match"
  read -s -p "Password: " user_password
  echo
  read -s -p "Repeat password: " user_password2
done

echo
echo "Would you like to use an existing SSH key?"
echo "Press 'n' if you want to generate a new SSH key pair"
echo
read -p "Use existing SSH key? [y/N]: " new_ssh_key_pair
until [[ "$new_ssh_key_pair" =~ ^[yYnN]*$ ]]; do
  echo "$new_ssh_key_pair: invalid selection."
  read -p "[y/N]: " new_ssh_key_pair
done
echo "enable_ssh_keygen: true" >>$HOME/$ANSIBLE_PROJECT/custom.yml

if [[ "$new_ssh_key_pair" =~ ^[yY]$ ]]; then
  echo
  read -p "Please enter your SSH public key: " ssh_key_pair

  echo "ssh_public_key: \"${ssh_key_pair}\"" >>$HOME/$ANSIBLE_PROJECT/custom.yml
fi

# Set secure permissions for the Vault file
touch $HOME/$ANSIBLE_PROJECT/secret.yml
echo "\n" >$HOME/$ANSIBLE_PROJECT/secret.yml
chmod 600 $HOME/$ANSIBLE_PROJECT/secret.yml

echo "user_password: \"${user_password}\"" >>$HOME/$ANSIBLE_PROJECT/secret.yml

jwt_secret=$(openssl rand -hex 23)
session_secret=$(openssl rand -hex 23)
storage_encryption_key=$(openssl rand -hex 23)

echo "jwt_secret: ${jwt_secret}" >>$HOME/$ANSIBLE_PROJECT/secret.yml
echo "session_secret: ${session_secret}" >>$HOME/$ANSIBLE_PROJECT/secret.yml
echo "storage_encryption_key: ${storage_encryption_key}" >>$HOME/$ANSIBLE_PROJECT/secret.yml

echo
echo "Encrypting the variables"
ansible-vault encrypt $HOME/$ANSIBLE_PROJECT/secret.yml

echo
echo "Success!"
read -p "Would you like to run the playbook now? [y/N]: " launch_playbook
until [[ "$launch_playbook" =~ ^[yYnN]*$ ]]; do
  echo "$launch_playbook: invalid selection."
  read -p "[y/N]: " launch_playbook
done

if [[ "$launch_playbook" =~ ^[yY]$ ]]; then
  if [[ $EUID -ne 0 ]]; then
    echo
    echo "Please enter your current sudo password now"
    cd $HOME/$ANSIBLE_PROJECT && ansible-playbook --ask-vault-pass -K run.yml
  else
    cd $HOME/$ANSIBLE_PROJECT && ansible-playbook --ask-vault-pass run.yml
  fi
else
  echo "You can run the playbook by executing the bootstrap script again:"
  echo "cd ~/$ANSIBLE_PROJECT && bash bootstrap.sh"
  exit
fi
