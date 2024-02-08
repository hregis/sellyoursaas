<?php

ini_set('display_errors', 1);
ini_set('display_startup_errors', 1);
error_reporting(E_ALL);

// ssh osu123456789@myinstance.withX.mysellyoursaasdomain.com
// hostkey can be:
// - ssh-rsa (old)
// - ecdsa-sha2-nistp256
// - rsa-sha2-256
// - rsa-sha2-512
$connection = ssh2_connect('myinstance.withX.mysellyoursaasdomain.com', 22, array('hostkey' => 'ecdsa-sha2-nistp256'));

var_dump($connection);

$methods = ssh2_methods_negotiated($connection);

echo "Encryption keys were negotiated using: {$methods['kex']}\n";
echo "Server identified using an {$methods['hostkey']} with ";
echo "fingerprint: " . ssh2_fingerprint($connection) . "\n";
