#!/usr/bin/perl



=head3 process_cclite_message

A crude first attempt to process GPG encoded Jabber input bodies
containing 'send' or 'balance' transactions. Does not send encrypted
receipts at present...

=cut

sub process_cclite_message {

    my ( $body, $user, $host, $res ) = @_;

    my ( $transaction_found, $transaction_line, $transaction_description_ref,
        $parse_type );

    # originator is mail style address, resource not used at present...
    my $originator = "$user\@$host";

    # if encoded, assumed to be a transaction...
    if ( $body =~ /BEGIN PGP MESSAGE/ ) {
        open( JABBER, ">$message_file" );
        print JABBER $body;
        close(JABBER);
        ( $transaction_found, $transaction_line ) =
          decode_decrypt_reformat( $passphrase, $message_file, $reformat,
            $decrypt, $logfile, $trace );

        ( $parse_type, $transaction_description_ref ) =
          mail_message_parse( 'local', $registry, $originator, '', '',
            $transaction_line );

        # add 'via jabber' literal to description of transaction
        $transaction_description_ref->{'description'} =
          "$messages{'viajabber'} "
          . $transaction_description_ref->{'description'};

#FIXME: we have output, error and text within transaction, needs simplifying
# also add the Via Jabber/Via Email prefix at this stage before transaction processing...
        if ( !length( $transaction_description_ref->{'error'} )
            && $transaction_description_ref->{'type'} eq 'send' )
        {
            $transaction_description_ref->{'output_message'} =
              mail_transaction($transaction_description_ref);
        } elsif ( $transaction_description_ref->{'type'} eq 'balance' ) {

            ###my $text = $transaction_description_ref->{'text'} ;
            ###my $type = $transaction_description_ref->{'type'};
            ###$log->debug("balance transaction t:$text ty:$type");

            $transaction_description_ref->{'output_message'} =
              $transaction_description_ref->{'text'};
        }

    }

    my $output =
"$transaction_description_ref->{'error'} $transaction_description_ref->{'output_message'}";
    my $type = $transaction_description_ref->{'type'};

    if ( !$transaction_found ) {
      return "no transaction detected" ;
    } else {
         return "$transaction_description_ref->{'error'} $transaction_description_ref->{'output_message'}";
    }

}

use strict ;
use lib '../../../lib';
use utf8;
use AnyEvent;
use AnyEvent::XMPP::IM::Connection;
use AnyEvent::XMPP::IM::Presence;
use AnyEvent::XMPP::Util qw/split_jid/;

use Log::Log4perl;

# and cclite support
use Ccconfiguration;
use Ccmailgateway;
use Cclitedb;
use Cclite;
use Cccrypto;
use Cccookie;
use Ccu;

# use pid to distinguish instances and jid for files
our $pid = $$ ;

my %configuration          = readconfiguration;
my $configuration_hash_ref = \%configuration;

# message language now decided by decide_language 08/2011
our %messages = readmessages();

Log::Log4perl->init( $configuration{'loggerconfig'} );
our $log = Log::Log4perl->get_logger("read_from_jabber");

# don't need at present run from command line...
my $cookieref = get_cookie();

# specific configuration file for this, for the moment...
my %jabber_configuration = readconfiguration('../../../config/readjabber.cf');

my $server   = $jabber_configuration{'server'};
my $port     = $jabber_configuration{'port'} || 5222 ;
my $server_user = $jabber_configuration{'username'};
my $server_password = $jabber_configuration{'password'};

# this is experimental, multiple cclite bots, distinguished by registry name
my $resource = $jabber_configuration{'hardcoded_registry'};

my $temp_directory = $jabber_configuration{'temp_directory'};

our $message_file =
  "$jabber_configuration{'temp_directory'}/$jabber_configuration{'message'}";
our $reformat =
  "$jabber_configuration{'temp_directory'}/$jabber_configuration{'reformat'}";
our $decrypt =
  "$jabber_configuration{'temp_directory'}/$jabber_configuration{'decrypt'}";
our $encrypted =
  "$jabber_configuration{'temp_directory'}/$jabber_configuration{'encrypted'}";

# STDERR for gpg operations, if specified...
our $logfile =
  "$jabber_configuration{'temp_directory'}/$jabber_configuration{'logfile'}";

# turns gpg trace on and off, prints to STDOUT (or STDERR?)
our $trace = $jabber_configuration{'trace'};

# sleep in seconds for processing loop, not needed...
our $sleep = $jabber_configuration{'sleep'};

# clearly this is very insecure, should be held as a smartcard token for example, this
# passphrase unlocks the private key for decrpyting the incoming transactions
# users private key on client is used to sign transactions

# note the key and the running user must correspond, otherwise the key won't get released by gpg
our $passphrase = $jabber_configuration{'passphrase'};

# this will leave data in the intermediate files and mail in the mailbox, if set to 1, avoids
# resetting/resending etc. when debugging
my $debug = $jabber_configuration{'debug'};

# for cron, replace these with hardcoded registry name
our $registry = $jabber_configuration{'hardcoded_registry'}
  || $$cookieref{registry};




# print out all the values in the configuration file, if debugging...
if ($debug) {
    foreach my $key ( keys %jabber_configuration ) {
        print "$key = $jabber_configuration{$key}\n";

    }
}

my $counter = 'a' ;
my $pres ;
my %replies;

my $j = AnyEvent->condvar;

# Enter your credentials here
my  $cl = AnyEvent::XMPP::IM::Connection->new (
      jid              => "$server_user@$server",
      password         => $server_password,
   );

 
 # The Connection object ($con here), is
 # always the first argument in the call backs. 
$cl->reg_cb (
   session_ready => sub {
      my ($con, $acc) = @_;
      print "session ready\n";
   },
   connect => sub {
      print "Connected \n";
   },
   message => sub {
      my ($con, $msg) = @_;
      if ($msg->any_body ne ""){
         my ($user, $host, $res) = split_jid ($msg->from);
         my $username = join("", $user,'@',$host);
 
 
         my $output = process_cclite_message ( $msg, $user, $host, $res );

         print "Message from " . $username . ":\n";
         print "Message: " . $msg->any_body . "\n";
         print "\n";
         
        my $immsg = AnyEvent::XMPP::IM::Message->new (to => $username, body => $output);
        $immsg->send ($con) ; 
      }
   },
   stream_pre_authentication => sub {
      print "Pre-authentication \n";
   },
   disconnect => sub {
      my ($con, $h, $p, $reason) = @_;
      warn "Disconnected from $h:$p: $reason\n";
      $j->broadcast;
   },
   error => sub {
      my ($cl, $err) = @_;
      print "ERROR: " . $err->string . "\n";
   },
   roster_update => sub {
      my ($con, $roster, $contacts) = @_;
      for my $contact ($roster->get_contacts) {
         print "Roster Update: " . $contact->jid . "\n";
      }
   },
   presence_update => sub {
      my ($con, $roster, $contacts, $old_presence, $new_presence) = @_;
      for my $cont ($contacts) {
         if($pres = $cont->get_priority_presence ne undef){
            # When user is online
            print "contact: " . $cont->jid . "\n";
            print "Presence: " . $pres . "\n";
            print "Status: " . $new_presence->show . "\n";
            print "Status Message: " . $new_presence->status . "\n";

            if ($cont->is_on_roster ne undef){
               print "Is On Roster: " . $cont->is_on_roster() . "\n";
            }
         } else {
            # When user has logged off
            print $cont->jid . "\n";
            print "Status offline \n";
         }
      }
   },
   message_error => sub {
      print "error";
   }
);
$cl->connect();
$j->wait;