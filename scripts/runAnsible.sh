#!/bin/sh

# Exit immediately if a simple command exits with a nonzero exit value
set -e

echo "Running Ansible playbooks..."
ansible-playbook -i ansible/inventory.ini ansible/preflight.yml
ansible-playbook -i ansible/inventory.ini ansible/lb.yml
ansible-playbook -i ansible/inventory.ini ansible/nodes.yml
ansible-playbook -i ansible/inventory.ini ansible/servers.yml
ansible-playbook -i ansible/inventory.ini ansible/agents.yml
ansible-playbook -i ansible/inventory.ini ansible/validate.yml
