--TEST--
Testing ftp_get_option basic functionality
--CREDITS--
Gabriel Caruso (carusogabriel34@gmail.com)
--SKIPIF--
<?php require 'skipif.inc'; ?>
--FILE--
<?php
require 'server.inc';
define('FOO_BAR', 10);

$ftp = ftp_connect('127.0.0.1', $port);
ftp_login($ftp, 'user', 'pass');
$ftp or die("Couldn't connect to the server");

var_dump(ftp_get_option($ftp, FTP_TIMEOUT_SEC));
var_dump(ftp_get_option($ftp, FTP_AUTOSEEK));
var_dump(ftp_get_option($ftp, FTP_USEPASVADDRESS));
var_dump(ftp_get_option($ftp, FOO_BAR));
?>
--EXPECTF--
int(%d)
bool(true)
bool(true)

Warning: ftp_get_option(): Unknown option '10' in %s on line %d
bool(false)
