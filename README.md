# centos\_samba_domain
### install\_pdc installation du contrôleur de domaine principal
### install\_sdc installation du contrôleur de domaine secondaire
### sysvol\_sync synchronisation par osync des stratégies de groupe
commencer par installer osync :
```shell
git clone https://github.com/deajan/osync.git
cd osync
./install.sh
```
copier ensuite le fichier _sysvol_sync.conf_ dans le dossier _/etc/osync/_
tester avec la commande suivante `/usr/local/bin/osync.sh /etc/osync/sysvol_sync.conf --verbose`
terminer en installer le cronjob suivant pour une synchronisation toutes les 5 minutes :
```shell
*/5 * * * * /usr/local/bin/osync.sh /etc/osync/sysvol_sync.conf --silent
```
### base\_backup script de base pour backup sur dédié
