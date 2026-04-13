# FortiAiGate_Setup_Tool
Tool to aid in setting up kubernetes  with calico networking and other dependencies to enable the ability to install FortiAiGate

Start with clean install of Ubuntu Server 24.04 LTS, 


# Installation
Place this program file into the same directory as all the .tar files aquired for FortiAiGate and do the following:

git clone https://github.com/ppogreba/FortiAiGate_Setup_Tool.git

cd FortiAiGate_Setup_Tool

nano FortiAiGate_Setup_Tool.sh 

##editable variables at the top to meet your network requirements

local_as="64512"

k8s_cidr="10.244.0.0/16"

## Make Executable and run
chmod +x FortiAiGate_Setup_Tool.sh

./FortiAiGate_Setup_Tool.sh
