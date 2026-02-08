oldns="ns1.[oldnameserver.tld]"; newns="ns1.[newnameserver.tld]" ; find /var/named/*.db -exec perl -pi -e "s/(?<=IN\s\NS\s)$oldns/$newns/g" '{}' \;
oldns="ns2.[oldnameserver.tld]"; newns="ns2.[newnameserver.tld]" ; find /var/named/*.db -exec perl -pi -e "s/(?<=IN\s\NS\s)$oldns/$newns/g" '{}' \;
find /var/named/*.db -mtime -1 -exec perl -pi -e 'if (/^\s+(\d{10})\s+;\s?(?i)serial/i) { my $i = $1+1; s/$1/$i/;}' '{}' \;
/scripts/restartsrv_named