#Initial script to run to enable BOS remote scripting on nodes

#Enable PSRemoting applet
Enable-PSRemoting -Force

#Set subnet to trusted list
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "10.0.0.*" -Concatenate -Force

