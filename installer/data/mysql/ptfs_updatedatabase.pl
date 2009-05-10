## For 1-34
ALTER TABLE `borrowers` ADD `password_plaintext` VARCHAR( 100 ) NULL AFTER `password` ;

INSERT INTO `systempreferences` ( `variable` , `value` , `options` , `explanation` , `type` )
 VALUES (
 'StorePasswordPlaintext', '0', '', 'If turned on, the passwords for all nonstaff accounts will be stored unencrypted and show in the password field on the change password screen.', 'YesNo'
 ) 