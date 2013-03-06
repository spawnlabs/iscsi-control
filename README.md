iscsi-control
=============

Easy to use command line tool for managing iscsi-backed drives (as compared to using iscsicli and diskpart) 

Usage
-----

### Query State
So you want to know the state of all iscsi connections associated with the machine?  

In this case, just run the command with no arguments in an adminstrative powershell:

```
&.\iscsi-control.ps1
TODO: show output (needs cleanup first. right now just dumps hash of info)
```

### Mount

This command will make a Q drive against the server specified by 'mountServer' and the iqn specified by 'mountIqn' 
```
&.\iscsi-control.ps1 -mount -mountServer 10.0.0.15 -mountIqn iqn.1986-03.com.sun:02:53d9bbce-0836-6928-d631-968c49b46b40 -mountDriveLetter Q
```

### Unmount

#### Unmount All Iscsi-Controlled Drives

Any drive mounted against a iscsi connection will be disconnected.
```
&.\iscsi-control.ps1 -unmount
```

#### Unmount Specific Drive

Only the drive letter, if found, will be disconnected from iscsi.
```
&.\iscsi-control.ps1 -unmount -driveLetter Q
```


