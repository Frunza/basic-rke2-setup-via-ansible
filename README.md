# Basic RKE2 setup via Ansible

## Goal

Set up `RKE2` via `Ansible` to use it in a non-production environment.

Note: `Ansible` needs SSH access to the target machine. You can find out how to configure SSH access in the docker container at [https://github.com/Frunza/configure-docker-container-with-ssh-access](https://github.com/Frunza/configure-docker-container-with-ssh-access)

## Prerequisites

A Linux or MacOS machine for local development. If you are running Windows, you first need to set up the *Windows Subsystem for Linux (WSL)* environment.

You need `docker cli` on your machine for testing purposes, and/or on the machines that run your pipeline.
You can check this by running the following command:
```sh
docker --version
```

A few virtual machines that you can use to set up a `RKE2 k8s` cluster. Make sure that you already have a docker container with SSH access to all of the virtual machines.

## Containerization preparation

Let's prepare the setup to run everything in containers. First, let's create a `Dockerfile` where we set up `Ansible`:
```sh
# Dockerfile
FROM alpine:3.18.0

ARG SSH_PRIVATE_KEY
RUN mkdir -p /root/.ssh
RUN echo "$SSH_PRIVATE_KEY" | tr -d '\r' > /root/.ssh/id_rsa && chmod 600 /root/.ssh/id_rsa

RUN apk --no-cache add ansible=7.5.0-r0

COPY ./scripts /app
COPY ./ansible /app/ansible
```
Here we first add an SSH key via a build argument, which we provide as an environment variable. We then create the directory and copy the content of the argument into a file at the correct location. The next step is to install `Ansible`, which we do by using a fixed version. At the end we copy our own stuff.
Now we can create a `Docker` compose file with a service that runs `Ansible`:
```sh
services:
  main:
    image: ansiblerke2
    network_mode: host
    working_dir: /app
    environment:
      - RKE2_TOKEN=${RKE2_TOKEN}
      # location of ansible config: https://docs.ansible.com/ansible/latest/reference_appendices/config.html#ansible-configuration-settings-locations
      - ANSIBLE_CONFIG=/app/ansible/ansible.cfg
    entrypoint: ["sh", "-c"]
    command: ["sh runAnsible.sh"]
```
The service is called *main*, and it runs a script for `Ansible`. We also have an environment variables with the SSH key needed to connect to the virtual machines, used by `Ansible`.

Before we get to the content of *runAnsible.sh*, let's talk a bit about how this looks like. Let's say we want to have 3 control plane nodes and 2 worker nodes. For this scenario, you do need an extra virtual machine to act like a load balancer for your control plane nodes. With that in mind, we will have more `Ansible` playbooks to set up the load balancer virtual machine, another one to do common setup on all virtual machines, and 2 other playbooks to set up the control plane nodes and the worker nodes.

The *runAnsible.sh* script just runs our `Ansible` playbooks, and looks like:
```sh
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
```
We will get to the content of the playbooks later on.

This is the boilerplate to run everything in containers. Now we can focus on setting up `RKE2` via `Ansible`.

## Implementation

Let's first create some basic `Ansible` configuration:
```sh
# ansible/ansible.cfg
[defaults]
host_key_checking = False
remote_user = ubuntu
interpreter_python = auto_silent

[privilege_escalation]
become = True
become_method = sudo
become_user = root
```
Depending on your virtual machines, you might want to set the *remote_user* to root also, if you so desire.
The inventory file can look like:
```sh
# ansible/inventory.ini
[lb]
192.168.2.1

[servers]
192.168.2.2
192.168.2.3
192.168.2.4

[agents]
192.168.2.5
192.168.2.6
```
Don't forget to update the hosts with your target virtual machines.

Now let's get to the playboks.

First of all, let's go over the validation playbook:
```sh
# ansible/preflight.yml
- name: Validate cluster inventory
  hosts: localhost
  gather_facts: false

  tasks:
    - name: Ensure exactly one load balancer exists
      ansible.builtin.assert:
        that:
          - groups['lb'] is defined
          - groups['lb'] | length == 1
        fail_msg: "Inventory must define exactly one host in [lb]"

    - name: Ensure at least one server exists
      ansible.builtin.assert:
        that:
          - groups['servers'] | length > 0
        fail_msg: "Inventory must define at least one server"

    - name: Ensure at least one agent exists
      ansible.builtin.assert:
        that:
          - groups['agents'] | length > 0
        fail_msg: "Inventory must define at least one agent"
```
Here we only check that we have exactly one load balancer, and at least one server and agent. Feel free to modify this for your environmet. Since the script that calls this playbook exists after the first failure, we do not have to recheck this in the other plabooks. If you structure the project different, you might have to check this more often.

The playbook to set up the load balancer looks like:
```sh
# ansible/lb.yml
- name: Configure HAProxy for RKE2
  hosts:
    - lb
  gather_facts: true
  become: true
  vars:
    rke2RegistrationPort: 9345
    rke2ApiPort: 6443
    haproxyBalanceMethod: roundrobin

  tasks:
    - name: Install haproxy
      ansible.builtin.apt:
        name: haproxy
        state: present
        update_cache: true

    - name: Build HAProxy backend server list
      ansible.builtin.set_fact:
        haproxyServers: |
          {% for host in groups['servers'] %}
          server {{ host | replace('.', '-') }} {{ hostvars[host].ansible_host | default(host) }}:{{ rke2RegistrationPort }} check
          {% endfor %}

    - name: Build HAProxy backend API list
      ansible.builtin.set_fact:
        haproxyApiServers: |
          {% for host in groups['servers'] %}
          server {{ host | replace('.', '-') }} {{ hostvars[host].ansible_host | default(host) }}:{{ rke2ApiPort }} check
          {% endfor %}

    - name: Write haproxy configuration
      ansible.builtin.copy:
        dest: /etc/haproxy/haproxy.cfg
        mode: "0644"
        content: |
          global
            daemon
            maxconn 2048

          defaults
            mode tcp
            timeout connect 10s
            timeout client 1m
            timeout server 1m

          frontend rke2_registration
            bind *:{{ rke2RegistrationPort }}
            default_backend rke2_registration_backend

          backend rke2_registration_backend
            balance {{ haproxyBalanceMethod }}
            option tcp-check
          {{ haproxyServers }}

          frontend kube_api
            bind *:{{ rke2ApiPort }}
            default_backend kube_api_backend

          backend kube_api_backend
            balance {{ haproxyBalanceMethod }}
            option tcp-check
          {{ haproxyApiServers }}
      notify: restart haproxy

    - name: Ensure haproxy is running
      ansible.builtin.systemd:
        name: haproxy
        enabled: true
        state: started

  handlers:
    - name: restart haproxy
      ansible.builtin.systemd:
        name: haproxy
        state: restarted
```
This playbook sets up `HAProxy` to distribute traffic to multiple `RKE2` server nodes, handling both the `RKE2` registration traffic (port 9345) and `k8s` API traffic (port 6443).
The first tasks installs [HAProxy](https://www.haproxy.org/), which stands for *High Availability Proxy*.
The second and third tasks create `Jinja2` templates for the control plane nodes for ports 9345 and 6443. The control plane nodes are retrieved from `Ansible`'s inventory file. We need to use `Jinja2` templates to create pieces of a configuration in a dynamic way.
The fourth task creates a configuration file for `HAProxy` where the `Jinja2` templates that we created previously are used. At the end we notify a restart for `HAProxy`, which is handled at the end.
The last task ensures that `HAProxy` is running and starts at boot.

We can now apply necessary `RKE2` configuration to all nodes:
```sh
# ansible/nodes.yml
- name: Basic configuration for all RKE2 nodes
  hosts:
    - servers
    - agents
  gather_facts: true
  become: true
  vars:
    k8sPackages:
      - curl
      - ca-certificates
    k8sKernelModules:
      - overlay
      - br_netfilter
    k8sSysctl:
      net.ipv4.ip_forward: "1"
      net.bridge.bridge-nf-call-iptables: "1"
      net.bridge.bridge-nf-call-ip6tables: "1"

  tasks:
    - name: Install Kubernetes prerequisite packages
      ansible.builtin.apt:
        name: "{{ k8sPackages }}"
        state: present
        update_cache: true

    - name: Ensure kernel modules load at boot
      ansible.builtin.copy:
        dest: /etc/modules-load.d/k8s.conf
        mode: "0644"
        content: |
          {% for module in k8sKernelModules %}
          {{ module }}
          {% endfor %}

    - name: Load kernel modules now
      ansible.builtin.command: "modprobe {{ item }}"
      loop: "{{ k8sKernelModules }}"
      changed_when: false

    - name: Configure sysctl settings for Kubernetes
      ansible.builtin.copy:
        dest: /etc/sysctl.d/90-k8s.conf
        mode: "0644"
        content: |
          {% for key, value in k8sSysctl.items() %}
          {{ key }} = {{ value }}
          {% endfor %}
      notify: apply sysctl

    - name: Disable swap immediately if enabled
      ansible.builtin.command: swapoff -a
      when: ansible_swaptotal_mb | int > 0
      changed_when: ansible_swaptotal_mb | int > 0

    - name: Disable swap in fstab
      ansible.builtin.replace:
        path: /etc/fstab
        regexp: '^(?!#)(.+\s+swap\s+.+)$'
        replace: '# \1'

  handlers:
    - name: apply sysctl
      ansible.builtin.command: sysctl --system
      changed_when: false
```
The first task in the playbook installs `curl`, which is needed for downloading `RKE2` binaries, pulling container images, etc. and `ca-certificates`, which is needed for HTTPS.
The second task creates a configuration file that tells the system to load kernel modules automatically on boot. The `overlay` module enables `OverlayFS`, a odern filesystem used by container runways for efficient layer-based image storage, and the `br_netfilter` module allows bridged network traffic to pass through iptables, enabling `k8s` network policies. The next tasks loads this modules right away, making them available for the current session.
The forth task creates a *systemd sysctl* configuration file that persists across reboots. Note that the name of the configuration is *90-k8s.conf*, whcih starts with 90, making it to load after default configurations; a lower number makes it load faster. It this configuration we want to set *net.ipv4.ip_forward=1* to enable `k8s` networking and *bridge-nf-call* settings for container networking. At the end we notify a handler to apply our configuration immediately.
The fifth task disables swap if it is enabled.
The last task comments out swap entries in */etc/fstab* to prevent swap from re-enabling after reboot by commenting out lines that contain *swap*. Depending on your setup, you might not need this task, but there's no harm in running it either way.

Before we move on, let's take a closer look over what we want to achieve. We want to be able to configure more `RKE2 k8s` control plane nodes. This makes a difference because we can only have a single bootstrap server, while the others are joining.
Let's define some variables which we can use for all nodes:
```sh
# group_vars/all.yml
rke2Version: "{{ lookup('env', 'RKE2_VERSION') | default('v1.35.1+rke2r1', true) }}"
rke2Token: "{{ lookup('env', 'RKE2_TOKEN') }}"
rke2ConfigDir: /etc/rancher/rke2
rke2ConfigFile: /etc/rancher/rke2/config.yaml
rke2InstallScriptUrl: https://get.rke2.io
rke2RegistrationPort: 9345

rke2RegistrationHost: "{{ groups['lb'][0] }}"
rke2RegistrationAddress: "{{ rke2RegistrationHost }}"
```
, and a few more which we can use for the `RKE2` servers:
```sh
# group_vars/servers.yml
rke2KubeconfigMode: "0644"
rke2BootstrapHost: "{{ groups['servers'][0] }}"
```

Since there is only one boostrap host, it is added as a variable as the first machine from the hosts: *rke2BootstrapHost: "{{ groups['servers'][0] }}"*. Note that we register the hosts with the load balancer: *rke2RegistrationHost: "{{ groups['lb'][0] }}"*. This has the advantage that we can use more servers for high availablity environments, as well as one srver for trying things out.
The *rke2Version* takes it value from the RKE2_VERSION environment variable if it exists, or from a default value otherwise.

The following playbook configures `RKE2` server nodes in a high-availability configuration:
```sh
# ansible/servers.yml
- name: Install and configure RKE2 servers
  hosts: servers
  gather_facts: true
  become: true
  serial: 1

  tasks:
    - name: Ensure config directory exists
      ansible.builtin.file:
        path: "{{ rke2ConfigDir }}"
        state: directory
        owner: root
        group: root
        mode: "0755"

    - name: Install RKE2 server
      ansible.builtin.shell: curl -sfL {{ rke2InstallScriptUrl }} | INSTALL_RKE2_VERSION={{ rke2Version }} sh -
      args:
        creates: /usr/local/bin/rke2

    - name: Write bootstrap server config
      ansible.builtin.copy:
        dest: "{{ rke2ConfigFile }}"
        owner: root
        group: root
        mode: "0600"
        content: |
          token: {{ rke2Token }}
          write-kubeconfig-mode: "{{ rke2KubeconfigMode }}"
          tls-san:
            - {{ rke2RegistrationAddress }}
            - 127.0.0.1
            - localhost
            {% for host in groups['servers'] %}
            - {{ hostvars[host].ansible_host | default(host) }}
            {% endfor %}
      when: inventory_hostname == rke2BootstrapHost
      notify: restart rke2-server

    - name: Write joining server config
      ansible.builtin.copy:
        dest: "{{ rke2ConfigFile }}"
        owner: root
        group: root
        mode: "0600"
        content: |
          server: https://{{ rke2RegistrationAddress }}:{{ rke2RegistrationPort }}
          token: {{ rke2Token }}
          write-kubeconfig-mode: "{{ rke2KubeconfigMode }}"
          tls-san:
            - {{ rke2RegistrationAddress }}
            - 127.0.0.1
            - localhost
            {% for host in groups['servers'] %}
            - {{ hostvars[host].ansible_host | default(host) }}
            {% endfor %}
      when: inventory_hostname != rke2BootstrapHost
      notify: restart rke2-server

    - name: Ensure rke2-server is enabled and started
      ansible.builtin.systemd:
        name: rke2-server
        enabled: true
        state: started

    - name: Wait for registration port via load balancer
      ansible.builtin.wait_for:
        host: "{{ rke2RegistrationAddress }}"
        port: "{{ rke2RegistrationPort }}"
        delay: 5
        timeout: 300
      delegate_to: localhost
      become: false
      when: inventory_hostname == rke2BootstrapHost

    - name: Wait for node-token to exist on bootstrap server
      ansible.builtin.wait_for:
        path: /var/lib/rancher/rke2/server/node-token
        timeout: 300
      when: inventory_hostname == rke2BootstrapHost

  handlers:
    - name: restart rke2-server
      ansible.builtin.systemd:
        name: rke2-server
        state: restarted
```
Because there is only one bootstrap server, the *serial: 1* setting is used; you will also notice that some tasks are are enabled for the bootstrap host, whle others are not.
The first task creates the directory where the `RKE2` configuration should be located, and the second task runs the `RKE2` intallation script. It is good practice to use a specific `RKE2` version instead of using the latest one. When we run the installation script, we use the INSTALL_RKE2_VERSION to specify the `RKE2` version, which value we take from the *rke2Version* variable. Note that INSTALL_RKE2_VERSION is specific to the `RKE2` installation script, while RKE2_VERSION used in the *rke2Version* variable is an environment variable we defined ourselves.
The next two tasks create `RKE2` configuration files for the bootstrap server and the joining servers. This is done using a *where* option, and both tasks notify `RKE2` to restart.
The fifth task just starts the `RKE2` server.
The sixth task waits for the bootstrap server to be ready to accept new server nodes, and the last one waits for the node token to be available for the bootstrap node.

The last thing to do is to configure the `RKE2` agents:
```sh
# ansible/agents.yml
- name: Install and configure RKE2 agents
  hosts: agents
  gather_facts: true
  become: true

  tasks:
    - name: Ensure config directory exists
      ansible.builtin.file:
        path: "{{ rke2ConfigDir }}"
        state: directory
        owner: root
        group: root
        mode: "0755"

    - name: Install RKE2 agent
      ansible.builtin.shell: curl -sfL {{ rke2InstallScriptUrl }} | INSTALL_RKE2_TYPE=agent INSTALL_RKE2_VERSION={{ rke2Version }} sh -
      args:
        creates: /usr/local/bin/rke2

    - name: Write agent config
      ansible.builtin.copy:
        dest: "{{ rke2ConfigFile }}"
        owner: root
        group: root
        mode: "0600"
        content: |
          server: https://{{ rke2RegistrationAddress }}:{{ rke2RegistrationPort }}
          token: {{ rke2Token }}
      notify: restart rke2-agent

    - name: Ensure rke2-agent is enabled and started
      ansible.builtin.systemd:
        name: rke2-agent
        enabled: true
        state: started

  handlers:
    - name: restart rke2-agent
      ansible.builtin.systemd:
        name: rke2-agent
        state: restarted
```
The first task creates the directory where the `RKE2` configuration should be located, and the second task runs the `RKE2` intallation script. Just as before, we use a specific version for `RKE2`.
The third task creates `RKE2` configuration file for the *rke2-agent* and notifies a restart at the end.
The last task just starts the *rke2-agent*.

## Making sure it works

Now you can create a script to run everything:
```sh
#!/bin/sh

# Exit immediately if a simple command exits with a nonzero exit value
set -e

docker build --build-arg SSH_PRIVATE_KEY="$TARGET_MACHINE_SSH_PRIVATE_KEY" -t ansiblerke2 .
docker compose -f dockerCompose.yml run --rm main
```

The last playbook does basic testing via `Ansible`:
```yaml
# ansible/validate.yml
- name: Validate RKE2 cluster
  hosts: servers[0]
  become: true
  vars:
    kubectlCmd: "/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
  tasks:
    - name: Wait for Kubernetes API to stabilize
      command: "{{ kubectlCmd }} get --raw=/readyz"
      register: apiReady
      retries: 30
      delay: 5
      until: apiReady.rc == 0
      changed_when: false

    - name: Wait for all nodes to become Ready
      command: "{{ kubectlCmd }} get nodes --no-headers"
      register: nodeStatus
      retries: 30
      delay: 10
      until: >
        nodeStatus.stdout_lines
        | select("search", " NotReady")
        | list
        | length == 0
      changed_when: false

    - name: Get nodes with their status
      command: "{{ kubectlCmd }} get nodes -o json"
      register: nodesJson
      changed_when: false
    
    - name: Parse node data
      set_fact:
        nodesList: "{{ (nodesJson.stdout | from_json)['items'] }}"
    
    - name: Check each node's Ready condition
      set_fact:
        notReadyNodes: "{{ notReadyNodes | default([]) + [item.metadata.name] }}"
      loop: "{{ nodesList }}"
      loop_control:
        label: "{{ item.metadata.name }}"
      when: item.status.conditions | selectattr('type', 'equalto', 'Ready') | map(attribute='status') | first != 'True'
    
    - name: Fail if any node is NotReady
      fail:
        msg: "The following nodes are NotReady: {{ notReadyNodes | join(', ') }}"
      when: notReadyNodes is defined and notReadyNodes | length > 0

    - name: Get system pods as JSON
      command: "{{ kubectlCmd }} get pods -n kube-system -o json"
      register: podsJson
      changed_when: false

    - name: Parse pod list
      set_fact:
        podList: "{{ (podsJson.stdout | from_json)['items'] }}"

    - name: Collect unhealthy pods
      set_fact:
        unhealthyPods: "{{ unhealthyPods | default([]) + [item.metadata.name] }}"
      loop: "{{ podList }}"
      loop_control:
        label: "{{ item.metadata.name }}"
      when: >
        (
          not item.metadata.name.startswith('helm-install-')
        )
        and
        (
          (
            item.status.phase not in ['Running', 'Succeeded']
          )
          or
          (
            item.status.containerStatuses is defined and
            (
              item.status.containerStatuses
              | selectattr('ready', 'equalto', false)
              | list
              | length > 0
            )
          )
        )

    - name: Fail if any pod is unhealthy
      fail:
        msg: "Unhealthy system pods: {{ unhealthyPods | join(', ') }}"
      when: unhealthyPods is defined and unhealthyPods | length > 0
```
The first tree tasks retrieve information about the nodes, and the fourth fails if not all nodes are ready.
The fifth task retrieves information about the *kube-system* pods, while the last task fails i not all pods are running.

If you want to play around with the cluster yourself, depending on your setup, you need to ssh into the bootstrap virtual machine to retrieve the *kubeconfig* file:
```sh
ssh ubuntu@192.168.2.2 "sudo cat /etc/rancher/rke2/rke2.yaml" > ~/.kube/config
```
Before you can start using the *kubeconfig* file you first need to do a replacement:
```sh
sed -i 's/127.0.0.1/192.168.2.2/g' ~/.kube/config
```

##  Considerations

While this setup uses a dedicated external load balancer (`HAProxy`) running on a separate virtual machine to provide a stable registration address and `k8s` API endpoint, several alternative approaches exist for achieving high availability in `RKE2` clusters. A popular modern option is `kube-vip`. Many bare-metal and on-premises deployments favor `kube-vip` for its simplicity and tight integration with `k8s`. Other patterns include round-robin DNS, cloud-provider elastic IPs, or even keepalived and `HAProxy` pairs for additional redundancy on the load-balancer layer itself.
