# FortiAiGate_Setup_Tool
Tool to aid in setting up kubernetes  with calico networking and other dependencies to enable the ability to install FortiAiGate



## Installation
Place this program file into the same directory as all the .tar files aquired for FortiAiGate and do the following:

nano FortiAiGate_Setup_Tool.sh 

##editable variables at the top to meet your network requirements
local_as="64512"
k8s_cidr="10.244.0.0/16"


chmod +x FortiAiGate_Setup_Tool.sh
./FortiAiGate_Setup_Tool.sh
