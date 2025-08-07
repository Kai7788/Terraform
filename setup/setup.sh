#!/bin/bash
cp ./terraform-apply.sh /usr/local/bin/terraform-apply.sh
chmod +x /usr/local/bin/terraform-apply.sh
cp ./terraform-apply.service /etc/systemd/system/terraform-apply.service
systemctl daemon-reexec
systemctl enable terraform-apply.service
