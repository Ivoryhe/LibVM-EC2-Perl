package VM::EC2;

=head1 NAME

VM::EC2 - Control the Amazon EC2 and Eucalyptus Clouds

=head1 SYNOPSIS

 # set environment variables EC2_ACCESS_KEY, EC2_SECRET_KEY and/or EC2_URL
 # to fill in arguments automatically

 ## IMAGE AND INSTANCE MANAGEMENT
 # get new EC2 object
 my $ec2 = VM::EC2->new(-access_key => 'access key id',
                        -secret_key => 'aws_secret_key',
                        -endpoint   => 'http://ec2.amazonaws.com');

 # fetch an image by its ID
 my $image = $ec2->describe_images('ami-12345');

 # get some information about the image
 my $architecture = $image->architecture;
 my $description  = $image->description;
 my @devices      = $image->blockDeviceMapping;
 for my $d (@devices) {
    print $d->deviceName,"\n";
    print $d->snapshotId,"\n";
    print $d->volumeSize,"\n";
 }

 # run two instances
 my @instances = $image->run_instances(-key_name      =>'My_key',
                                       -security_group=>'default',
                                       -min_count     =>2,
                                       -instance_type => 't1.micro')
           or die $ec2->error_str;

 # wait for both instances to reach "running" or other terminal state
 $ec2->wait_for_instances(@instances);

 # print out both instance's current state and DNS name
 for my $i (@instances) {
    my $status = $i->current_status;
    my $dns    = $i->dnsName;
    print "$i: [$status] $dns\n";
 }

 # tag both instances with Role "server"
 foreach (@instances) {$_->add_tag(Role=>'server');

 # stop both instances
 foreach (@instances) {$_->stop}
 
 # find instances tagged with Role=Server that are
 # stopped, change the user data and restart.
 @instances = $ec2->describe_instances({'tag:Role'       => 'Server',
                                        'instance-state-name' => 'stopped'});
 for my $i (@instances) {
    $i->userData('Secure-mode: off');
    $i->start or warn "Couldn't start $i: ",$i->error_str;
 }

 # create an image from both instance, tag them, and make
 # them public
 for my $i (@instances) {
     my $img = $i->create_image("Autoimage from $i","Test image");
     $img->add_tags(Name  => "Autoimage from $i",
                    Role  => 'Server',
                    Status=> 'Production');
     $img->make_public(1);
 }

 ## KEY MANAGEMENT

 # retrieve the name and fingerprint of the first instance's 
 # key pair
 my $kp = $instances[0]->keyPair;
 print $instances[0], ": keypair $kp=",$kp->fingerprint,"\n";

 # create a new key pair
 $kp = $ec2->create_key_pair('My Key');
 
 # get the private key from this key pair and write it to a disk file
 # in ssh-compatible format
 my $private_key = $kp->private_key;
 open (my $f,'>MyKeypair.rsa') or die $!;
 print $f $private_key;
 close $f;

 # Import a preexisting SSH key
 my $public_key = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC8o...';
 $key = $ec2->import_key_pair('NewKey',$public_key);

 ## SECURITY GROUPS AND FIREWALL RULES
 # Create a new security group
 my $group = $ec2->create_security_group(-name        => 'NewGroup',
                                         -description => 'example');

 # Add a firewall rule 
 $group->authorize_incoming(-protocol  => 'tcp',
                            -port      => 80,
                            -source_ip => ['192.168.2.0/24','192.168.2.1/24'});

 # Write rules back to Amazon
 $group->update;

 # Print current firewall rules
 print join ("\n",$group->ipPermissions),"\n";

 ## VOLUME && SNAPSHOT MANAGEMENT

 # find existing volumes that are available
 my @volumes = $ec2->describe_volumes({status=>'available'});

 # back 'em all up to snapshots
 foreach (@volumes) {$_->snapshot('Backup on '.localtime)}

 # find a stopped instance in first volume's availability zone and 
 # attach the volume to the instance using /dev/sdg
 my $vol  = $volumes[0];
 my $zone = $vol->availabilityZone;
 @instances = $ec2->describe_instances({'availability-zone'=> $zone,
                                        'run-state-name'   => $stopped);
 $instances[0]->attach_volume($vol=>'/dev/sdg') if @instances;

 # create a new 20 gig volume
 $vol = $ec2->create_volume(-availability_zone=> 'us-east-1a',
                            -size             =>  20);
 $ec2->wait_for_volumes($vol);
 print "Volume $vol is ready!\n" if $vol->current_status eq 'available';

 # create a new elastic address and associate it with an instance
 my $address = $ec2->allocate_address();
 $instances[0]->associate_address($address);

=head1 DESCRIPTION

This is an interface to the 2012-12-01 version of the Amazon AWS API
(http://aws.amazon.com/ec2). It was written provide access to the new
tag and metadata interface that is not currently supported by
Net::Amazon::EC2, as well as to provide developers with an extension
mechanism for the API. This library will also support the Eucalyptus
open source cloud (http://open.eucalyptus.com).

The main interface is the VM::EC2 object, which provides methods for
interrogating the Amazon EC2, launching instances, and managing
instance lifecycle. These methods return the following major object
classes which act as specialized interfaces to AWS:

 VM::EC2::BlockDevice               -- A block device
 VM::EC2::BlockDevice::Attachment   -- Attachment of a block device to an EC2 instance
 VM::EC2::BlockDevice::EBS          -- An elastic block device
 VM::EC2::BlockDevice::Mapping      -- Mapping of a virtual storage device to a block device
 VM::EC2::BlockDevice::Mapping::EBS -- Mapping of a virtual storage device to an EBS block device
 VM::EC2::Group                     -- Security groups
 VM::EC2::Image                     -- Amazon Machine Images (AMIs)
 VM::EC2::Instance                  -- Virtual machine instances
 VM::EC2::Instance::Metadata        -- Access to runtime metadata from running instances
 VM::EC2::Region                    -- Availability regions
 VM::EC2::Snapshot                  -- EBS snapshots
 VM::EC2::Tag                       -- Metadata tags

In addition, there is a high level interface for interacting with EC2
servers and volumes, including file transfer and remote shell facilities:

  VM::EC2::Staging::Manager         -- Manage a set of servers and volumes.
  VM::EC2::Staging::Server          -- A staging server, with remote shell and file transfer
                                        facilities.
  VM::EC2::Staging::Volume          -- A staging volume with the ability to copy itself between
                                        availability zones and regions.

and a few specialty classes:

  VM::EC2::Security::Token          -- Temporary security tokens for granting EC2 access to
                                        non-AWS account holders.
  VM::EC2::Security::Credentials    -- Credentials for use by temporary account holders.
  VM::EC2::Security::Policy         -- Policies that restrict what temporary account holders
                                        can do with EC2 resources.
  VM::EC2::Security::FederatedUser  -- Account name information for temporary account holders.

Lastly, there are several utility classes:

 VM::EC2::Generic                   -- Base class for all AWS objects
 VM::EC2::Error                     -- Error messages
 VM::EC2::Dispatch                  -- Maps AWS XML responses onto perl object classes
 VM::EC2::ReservationSet            -- Hidden class used for describe_instances() request;
                                        The reservation Ids are copied into the Instance
                                         object.

There is also a high-level API called "VM::EC2::Staging::Manager" for
managing groups of staging servers and volumes which greatly
simplifies the task of creating and updating instances that mount
multiple volumes. The API also provides a one-line command for
migrating EBS-backed AMIs from one zone to another. See
L<VM::EC2::Staging::Manager>.

The interface provided by these modules is based on that described at
http://docs.amazonwebservices.com/AWSEC2/latest/APIReference/. The
following caveats apply:

 1) Not all of the Amazon API is currently implemented. Specifically,
    a handful calls dealing with cluster management and VM importing
    are missing.  See L</MISSING METHODS> for a list of all the
    unimplemented API calls. Volunteers to fill in these gaps are
    most welcome!

 2) For consistency with common Perl coding practices, method calls
    are lowercase and words in long method names are separated by
    underscores. The Amazon API prefers mixed case.  So in the Amazon
    API the call to fetch instance information is "DescribeInstances",
    while in VM::EC2, the method is "describe_instances". To avoid
    annoyance, if you use the mixed case form for a method name, the
    Perl autoloader will automatically translate it to underscores for
    you, and vice-versa; this means you can call either
    $ec2->describe_instances() or $ec2->DescribeInstances().

 3) Named arguments passed to methods are all lowercase, use
    underscores to separate words and start with hyphens.
    In other words, if the AWS API calls for an argument named
    "InstanceId" to be passed to the "DescribeInstances" call, then
    the corresponding Perl function will look like:

         $instance = $ec2->describe_instances(-instance_id=>'i-12345')

    In most cases automatic case translation will be performed for you
    on arguments. So in the previous example, you could use
    -InstanceId as well as -instance_id. The exception
    is when an absurdly long argument name was replaced with an 
    abbreviated one as described below. In this case, you must use
    the documented argument name.

    In a small number of cases, when the parameter name was absurdly
    long, it has been abbreviated. For example, the
    "Placement.AvailabilityZone" parameter has been represented as
    -placement_zone and not -placement_availability_zone. See the
    documentation for these cases.

 4) For each of the describe_foo() methods (where "foo" is a type of
    resource such as "instance"), you can fetch the resource by using
    their IDs either with the long form:

          $ec2->describe_foo(-foo_id=>['a','b','c']),

    or a shortcut form: 

          $ec2->describe_foo('a','b','c');

    Both forms are listed in the headings in the documentation.

 5) When the API calls for a list of arguments named Arg.1, Arg.2,
    then the Perl interface allows you to use an anonymous array for
    the consecutive values. For example to call describe_instances()
    with multiple instance IDs, use:

       @i = $ec2->describe_instances(-instance_id=>['i-12345','i-87654'])

 6) All Filter arguments are represented as a -filter argument whose value is
    an anonymous hash:

       @i = $ec2->describe_instances(-filter=>{architecture=>'i386',
                                               'tag:Name'  =>'WebServer'})

    If there are no other arguments you wish to pass, you can omit the
    -filter argument and just pass a hashref:

       @i = $ec2->describe_instances({architecture=>'i386',
                                      'tag:Name'  =>'WebServer'})

    For any filter, you may represent multiple OR arguments as an arrayref:

      @i = $ec2->describe-instances({'instance-state-name'=>['stopped','terminated']})

    When adding or removing tags, the -tag argument uses the same syntax.

 7) The tagnames of each XML object returned from AWS are converted into methods
    with the same name and typography. So the <privateIpAddress> tag in a
    DescribeInstancesResponse, becomes:

           $instance->privateIpAddress

    You can also use the more Perlish form -- this is equivalent:

          $instance->private_ip_address

    Methods that correspond to complex objects in the XML hierarchy
    return the appropriate Perl object. For example, an instance's
    blockDeviceMapping() method returns an object of type
    VM::EC2::BlockDevice::Mapping.

    All objects have a fields() method that will return the XML
    tagnames listed in the AWS specifications.

      @fields = sort $instance->fields;
      # 'amiLaunchIndex', 'architecture', 'blockDeviceMapping', ...

 8) Whenever an object has a unique ID, string overloading is used so that 
    the object interpolates the ID into the string. For example, when you
    print a VM::EC2::Volume object, or use it in another string context,
    then it will appear as the string "vol-123456". Nevertheless, it will
    continue to be usable for method calls.

         ($v) = $ec2->describe_volumes();
         print $v,"\n";                 # prints as "vol-123456"
         $zone = $v->availabilityZone;  # acts like an object

 9) Many objects have convenience methods that invoke the AWS API on your
    behalf. For example, instance objects have a current_status() method that returns
    the run status of the object, as well as start(), stop() and terminate()
    methods that control the instance's lifecycle.

         if ($instance->current_status eq 'running') {
             $instance->stop;
         }

 10) Calls to AWS that have failed for one reason or another (invalid
    arguments, communications problems, service interruptions) will
    return undef and set the VM::EC2->is_error() method to true. The
    error message and its code can then be recovered by calling
    VM::EC2->error.

      $i = $ec2->describe_instance('i-123456');
      unless ($i) {
          warn 'Got no instance. Message was: ',$ec2->error;
      }

    You may also elect to raise an exception when an error occurs.
    See the new() method for details.

=head1 API GROUPS

The extensive (and growing) Amazon API has many calls that you may
never need. To avoid the performance overhead of loading the
interfaces to all these calls, you may use Perl's import mechanism to
load only those you care about. By default, all methods are loaded.

Loading is controlled by the "use" import list, and follows the
conventions described in the Exporter module:

 use VM::EC2 'key','elastic_ip';  # load Key Pair and Elastic IP
				  # methods only

 use VM::EC2 ':standard';         # load all the standard methods

 use VM::EC2 ':standard','!key';  # load standard methods but not Key Pair

Related API calls are grouped together using the scheme described at
http://docs.aws.amazon.com/AWSEC2/latest/APIReference/OperationList-query.html. The
modules that define the API calls can be found in VM/EC2/REST/; you
can read their documentation by running perldoc VM::EC2::REST::"name
of module":

 perldoc VM::EC2::REST::elastic_ip

or using the VM::EC2 documentation script "ec2doc" (still to be
implemented!).

The groups that you can import are as follows:
 
 :standard => ami, ebs, elastic_ip, instance, keys, general,
              monitoring, tag, security_group, security_token, zone

 :vpc      => customer_gateway, dhcp, elastic_network_interface, 
              private_ip, internet_gateway, network_acl, route_table,
              vpc, vpn, vpn_gateway

 :misc     => devpay, monitoring, reserved_instance,
              spot_instance, vm_export, vm_import, windows

 :scaling  => elastic_load_balancer,autoscaling

 :hpc      => placement_group

 :all      => :standard, :vpn, :misc

 :DEFAULT  => :all
 
=head1 EXAMPLE SCRIPT

The script sync_to_snapshot.pl, distributed with this module,
illustrates a relatively complex set of steps on EC2 that does
something useful. Given a list of directories or files on the local
filesystem it copies the files into an EBS snapshot with the desired
name by executing the following steps:

1. Provisions a new EBS volume on EC2 large enough to hold the data.

2. Spins up a staging instance to manage the network transfer of data
from the local machine to the staging volume.

3. Creates a temporary ssh keypair and a security group that allows an
rsync-over-ssh.

4. Formats and mounts the volume if necessary.

5. Initiates an rsync-over-ssh for the designated files and
directories.

6. Unmounts and snapshots the volume.

7. Cleans up.

If a snapshot of the same name already exists, then it is used to
create the staging volume, enabling network-efficient synchronization
of the files. A snapshot tag named "Version" is incremented each time
you synchronize.

=head1 CORE METHODS

This section describes the VM::EC2 constructor, accessor methods, and
methods relevant to error handling.

=cut

use strict;

use VM::EC2::Dispatch;
use VM::EC2::ParmParser;

# replace with HTTP::AnyEvent
use LWP::UserAgent;
use HTTP::Request::Common;

use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA qw(hmac_sha256 sha1_hex);
use POSIX 'strftime';
use URI;
use URI::Escape;
use VM::EC2::Error;
use Carp 'croak','carp';

our $VERSION = '1.23';
our $AUTOLOAD;
our @CARP_NOT = qw(VM::EC2::Image    VM::EC2::Volume
                   VM::EC2::Snapshot VM::EC2::Instance
                   VM::EC2::ReservedInstance);

# hard-coded timeout for several wait_for_terminal_state() calls.
use constant WAIT_FOR_TIMEOUT => 600;

sub AUTOLOAD {
    my $self = shift;
    my ($pack,$func_name) = $AUTOLOAD=~/(.+)::([^:]+)$/;
    return if $func_name eq 'DESTROY';
    my $proper = VM::EC2->canonicalize($func_name);
    $proper =~ s/^-//;
    if ($self->can($proper)) {
	eval "sub $pack\:\:$func_name {shift->$proper(\@_)}";
	$self->$func_name(@_);
    } else {
	croak "Can't locate object method \"$func_name\" via package \"$pack\"";
    }
}

use constant import_tags => {
    ':standard' => [qw(instance elastic_ip ebs ami keys monitoring zone general tag security_group security_token)],
    ':vpc'      => [qw(customer_gateway dhcp elastic_network_interface private_ip 
                       internet_gateway network_acl route_table subnet vpc vpn vpn_gateway)],
    ':hpc'      => ['placement_group'],
    ':scaling'  => ['elastic_load_balancer','autoscaling'],
    ':misc'     => ['devpay','reserved_instance', 'spot_instance','vm_export','vm_import','windows'],
    ':all'      => [qw(:standard :vpc :hpc :scaling :misc)],
    ':DEFAULT'  => [':all'],
};

# e.g. use VM::EC2 ':default','!ami';
sub import {
    my $self = shift;
    my @args = @_;
    @args    = ':DEFAULT' unless @args;
    while (1) {
	my @processed = map {/^:/ && import_tags->{$_} ? @{import_tags->{$_}} : $_ } @args;
	last if "@processed" eq  "@args";  # no more expansion needed
	@args = @processed;
    }
    my (%excluded,%included);
    foreach (@args) {
	if (/^!(\S+)/) {
	    $excluded{$1}++ ;
	    $_ = $1;
	}
    }
    foreach (@args) {
	next unless /^\S/;
	next if $excluded{$_};
	next if $included{$_}++;
	croak "'$_' is not a valid import tag" if /^[!:]/;
	next if $INC{"VM/EC2/REST/$_.pm"};
	my $class = "VM::EC2::REST::$_";
	eval "require $class; 1" or die $@;
    }
}

=head2 $ec2 = VM::EC2->new(-access_key=>$id,-secret_key=>$key,-endpoint=>$url)

Create a new Amazon access object. Required arguments are:

 -access_key   Access ID for an authorized user

 -secret_key   Secret key corresponding to the Access ID

 -security_token Temporary security token obtained through a call to the
               AWS Security Token Service

 -endpoint     The URL for making API requests

 -region       The region to receive the API requests

 -raise_error  If true, throw an exception.

 -print_error  If true, print errors to STDERR.

One or more of -access_key or -secret_key can be omitted if the
environment variables EC2_ACCESS_KEY and EC2_SECRET_KEY are
defined. If no endpoint is specified, then the environment variable
EC2_URL is consulted; otherwise the generic endpoint
http://ec2.amazonaws.com/ is used. You can also select the endpoint by
specifying one of the Amazon regions, such as "us-west-2", with the
-region argument. The endpoint specified by -region will override
-endpoint.

-security_token is used in conjunction with temporary security tokens
returned by $ec2->get_federation_token() and $ec2->get_session_token()
to grant restricted, time-limited access to some or all your EC2
resources to users who do not have access to your account. If you pass
either a VM::EC2::Security::Token object, or the
VM::EC2::Security::Credentials object contained within the token
object, then new() does not need the -access_key or -secret_key
arguments. You may also pass a session token string scalar to
-security_token, in which case you must also pass the access key ID
and secret keys generated at the same time the session token was
created. See
http://docs.amazonwebservices.com/AWSEC2/latest/UserGuide/UsingIAM.html
and L</AWS SECURITY TOKENS>.

To use a Eucalyptus cloud, please provide the appropriate endpoint
URL.

By default, when the Amazon API reports an error, such as attempting
to perform an invalid operation on an instance, the corresponding
method will return empty and the error message can be recovered from
$ec2->error(). However, if you pass -raise_error=>1 to new(), the module
will instead raise a fatal error, which you can trap with eval{} and
report with $@:

  eval {
     $ec2->some_dangerous_operation();
     $ec2->another_dangerous_operation();
  };
  print STDERR "something bad happened: $@" if $@;

The error object can be retrieved with $ec2->error() as before.

=cut

sub new {
    my $self = shift;
    my %args = @_;

    my ($id,$secret,$token);
    if (ref $args{-security_token} && $args{-security_token}->can('access_key_id')) {
	$id     = $args{-security_token}->accessKeyId;
	$secret = $args{-security_token}->secretAccessKey;
	$token  = $args{-security_token}->sessionToken;
    }

    $id           ||= $args{-access_key} || $ENV{EC2_ACCESS_KEY}
                      or croak "Please provide -access_key parameter or define environment variable EC2_ACCESS_KEY";
    $secret       ||= $args{-secret_key} || $ENV{EC2_SECRET_KEY}
                      or croak "Please provide -secret_key or define environment variable EC2_SECRET_KEY";
    $token        ||= $args{-security_token};

    my $endpoint_url = $args{-endpoint}   || $ENV{EC2_URL} || 'http://ec2.amazonaws.com/';
    $endpoint_url   .= '/'                     unless $endpoint_url =~ m!/$!;
    $endpoint_url    = "http://".$endpoint_url unless $endpoint_url =~ m!https?://!;

    my $raise_error  = $args{-raise_error};
    my $print_error  = $args{-print_error};
    my $obj = bless {
	id              => $id,
	secret          => $secret,
	security_token  => $token,
	endpoint        => $endpoint_url,
	idempotent_seed => sha1_hex(rand()),
	raise_error     => $raise_error,
	print_error     => $print_error,
    },ref $self || $self;

    if ($args{-region}) {
	$self->import('zone');
	my $region   = eval{$obj->describe_regions($args{-region})};
	my $endpoint = $region ? $region->regionEndpoint :"ec2.$args{-region}.amazonaws.com";
	$obj->endpoint($endpoint);
    }

    return $obj;
}

=head2 $access_key = $ec2->access_key([$new_access_key])

Get or set the ACCESS KEY. In this and all similar get/set methods,
call the method with no arguments to get the current value, and with a
single argument to change the value:

 $current_key = $ec2->access_key;
 $ec2->access_key('XYZZY');

In the case of setting the value, these methods will return the old
value as their result:

 $old_key = $ec2->access_key($new_key);

=cut

sub access_key {shift->id(@_)}

sub id       { 
    my $self = shift;
    my $d    = $self->{id};
    $self->{id} = shift if @_;
    $d;
}

=head2 $secret = $ec2->secret([$new_secret])

Get or set the SECRET KEY

=cut

sub secret   {
    my $self = shift;
    my $d    = $self->{secret};
    $self->{secret} = shift if @_;
    $d;
}

=head2 $secret = $ec2->security_token([$new_token])

Get or set the temporary security token. See L</AWS SECURITY TOKENS>.

=cut

sub security_token   {
    my $self = shift;
    my $d    = $self->{security_token};
    $self->{security_token} = shift if @_;
    $d;
}

=head2 $endpoint = $ec2->endpoint([$new_endpoint])

Get or set the ENDPOINT URL.

=cut

sub endpoint { 
    my $self = shift;
    my $d    = $self->{endpoint};
    if (@_) {
	my $new_endpoint = shift;
	$new_endpoint    = 'http://'.$new_endpoint
	    unless $new_endpoint =~ /^https?:/;
	$self->{endpoint} = $new_endpoint;
    }
    $d;
 }

=head2 $region = $ec2->region([$new_region])

Get or set the EC2 region manipulated by this module. This has the side effect
of changing the endpoint.

=cut

sub region { 
    my $self = shift;

    my $d    = $self->{endpoint};
    $d       =~ s!^https?://!!;
    $d       =~ s!/$!!;

    $self->import('zone');
    my @regions = $self->describe_regions;
    my ($current_region) = grep {$_->regionEndpoint eq $d} @regions;

    if (@_) {
	my $new_region = shift;
	my ($region) = grep {/$new_region/} @regions;
	$region or croak "unknown region $new_region";
	$self->endpoint($region->regionEndpoint);
    }
    return $current_region;
}

=head2 $ec2->raise_error($boolean)

Change the handling of error conditions. Pass a true value to cause
Amazon API errors to raise a fatal error. Pass false to make methods
return undef. In either case, you can detect the error condition
by calling is_error() and fetch the error message using error(). This
method will also return the current state of the raise error flag.

=cut

sub raise_error {
    my $self = shift;
    my $d    = $self->{raise_error};
    $self->{raise_error} = shift if @_;
    $d;
}

=head2 $ec2->print_error($boolean)

Change the handling of error conditions. Pass a true value to cause
Amazon API errors to print error messages to STDERR. Pass false to
cancel this behavior.

=cut

sub print_error {
    my $self = shift;
    my $d    = $self->{print_error};
    $self->{print_error} = shift if @_;
    $d;
}

=head2 $boolean = $ec2->is_error

If a method fails, it will return undef. However, some methods, such
as describe_images(), will also return undef if no resources matches
your search criteria. Call is_error() to distinguish the two
eventualities:

  @images = $ec2->describe_images(-owner=>'29731912785');
  unless (@images) {
      die "Error: ",$ec2->error if $ec2->is_error;
      print "No appropriate images found\n";
  }

=cut

sub is_error {
    defined shift->error();
}

=head2 $err = $ec2->error

If the most recently-executed method failed, $ec2->error() will return
the error code and other descriptive information. This method will
return undef if the most recently executed method was successful.

The returned object is actually an AWS::Error object, which
has two methods named code() and message(). If used in a string
context, its operator overloading returns the composite string
"$message [$code]".

=cut

sub error {
    my $self = shift;
    my $d    = $self->{error};
    $self->{error} = shift if @_;
    $d;
}

=head2 $err = $ec2->error_str

Same as error() except it returns the string representation, not the
object. This works better in debuggers and exception handlers.

=cut

sub error_str { 
    my $e = shift->{error};
    $e ||= '';
    return "$e";
}

=head2 $account_id = $ec2->account_id

Looks up the account ID corresponding to the credentials provided when
the VM::EC2 instance was created. The way this is done is to fetch the
"default" security group, which is guaranteed to exist, and then
return its groupId field. The result is cached so that subsequent
accesses are fast.

=head2 $account_id = $ec2->userId

Same as above, for convenience.

=cut

sub account_id {
    my $self = shift;
    return $self->{account_id} if exists $self->{account_id};
    my $sg   = $self->describe_security_groups(-group_name=>'default') or return;
    return $self->{account_id} ||= $sg->ownerId;
}

sub userId { shift->account_id }

=head2 $new_ec2 = $ec2->clone

This method creates an identical copy of the EC2 object. It is used
occasionally internally for creating an EC2 object in a different AWS
region:

 $singapore = $ec2->clone;
 $singapore->region('ap-souteast-1');

=cut

sub clone {
    my $self = shift;
    my %contents = %$self;
    return bless \%contents,ref $self;
}

=head1 Waiting for State Changes

The methods in this section allow your script to wait in an efficient
manner for desired state changes in instances, volumes and other
objects.

=head2 $ec2->wait_for_instances(@instances)

Wait for all members of the provided list of instances to reach some
terminal state ("running", "stopped" or "terminated"), and then return
a hash reference that maps each instance ID to its final state.

Typical usage:

 my @instances = $image->run_instances(-key_name      =>'My_key',
                                       -security_group=>'default',
                                       -min_count     =>2,
                                       -instance_type => 't1.micro')
           or die $ec2->error_str;
 my $status = $ec2->wait_for_instances(@instances);
 my @failed = grep {$status->{$_} ne 'running'} @instances;
 print "The following failed: @failed\n";

If no terminal state is reached within a set timeout, then this method
returns undef and sets $ec2->error_str() to a suitable message. The
timeout, which defaults to 10 minutes (600 seconds), can be get or set
with $ec2->wait_for_timeout().

=cut

sub wait_for_instances {
    my $self = shift;
    $self->wait_for_terminal_state(\@_,
				   ['running','stopped','terminated'],
				   $self->wait_for_timeout);
}

=head2 $ec2->wait_for_snapshots(@snapshots)

Wait for all members of the provided list of snapshots to reach some
terminal state ("completed", "error"), and then return a hash
reference that maps each snapshot ID to its final state.

This method may potentially wait forever. It has no set timeout. Wrap
it in an eval{} and set alarm() if you wish to timeout.

=cut

sub wait_for_snapshots {
    my $self = shift;
    $self->wait_for_terminal_state(\@_,
				   ['completed','error'],
				   0);  # no timeout on snapshots -- they may take days
}

=head2 $ec2->wait_for_volumes(@volumes)

Wait for all members of the provided list of volumes to reach some
terminal state ("available", "in-use", "deleted" or "error"), and then
return a hash reference that maps each volume ID to its final state.

If no terminal state is reached within a set timeout, then this method
returns undef and sets $ec2->error_str() to a suitable message. The
timeout, which defaults to 10 minutes (600 seconds), can be get or set
with $ec2->wait_for_timeout().

=cut

sub wait_for_volumes {
    my $self = shift;
    $self->wait_for_terminal_state(\@_,
				   ['available','in-use','deleted','error'],
				   $self->wait_for_timeout);
}

=head2 $ec2->wait_for_attachments(@attachment)

Wait for all members of the provided list of
VM::EC2::BlockDevice::Attachment objects to reach some terminal state
("attached" or "detached"), and then return a hash reference that maps
each attachment to its final state.

Typical usage:

    my $i = 0;
    my $instance = 'i-12345';
    my @attach;
    foreach (@volume) {
	push @attach,$_->attach($instance,'/dev/sdf'.$i++;
    }
    my $s = $ec2->wait_for_attachments(@attach);
    my @failed = grep($s->{$_} ne 'attached'} @attach;
    warn "did not attach: ",join ', ',@failed;

If no terminal state is reached within a set timeout, then this method
returns undef and sets $ec2->error_str() to a suitable message. The
timeout, which defaults to 10 minutes (600 seconds), can be get or set
with $ec2->wait_for_timeout().

=cut

sub wait_for_attachments {
    my $self = shift;
    $self->wait_for_terminal_state(\@_,
				   ['attached','detached'],
				   $self->wait_for_timeout);
}

=head2 $ec2->wait_for_terminal_state(\@objects,['list','of','states'] [,$timeout])

Generic version of the last four methods. Wait for all members of the provided list of Amazon objects 
instances to reach some terminal state listed in the second argument, and then return
a hash reference that maps each object ID to its final state.

If a timeout is provided, in seconds, then the method will abort after
waiting the indicated time and return undef.

=cut

sub wait_for_terminal_state {
    my $self = shift;
    my ($objects,$terminal_states,$timeout) = @_;
    my %terminal_state = map {$_=>1} @$terminal_states;
    my %status = ();
    my @pending = grep {defined $_} @$objects; # in case we're passed an undef
    my $status = eval {
	local $SIG{ALRM};
	if ($timeout && $timeout > 0) {
	    $SIG{ALRM} = sub {die "timeout"};
	    alarm($timeout);
	}
	while (@pending) {
	    sleep 3;
	    $status{$_} = $_->current_status foreach @pending;
	    @pending    = grep { !$terminal_state{$status{$_}} } @pending;
	}
	alarm(0);
	\%status;
    };
    if ($@ =~ /timeout/) {
	$self->error('timeout waiting for terminal state');
	return;
    }
    return $status;
}

=head2 $timeout = $ec2->wait_for_timeout([$new_timeout]);

Get or change the timeout for wait_for_instances(), wait_for_attachments(),
and wait_for_volumes(). The timeout is given in seconds, and defaults to
600 (10 minutes). You can set this to 0 to wait forever.

=cut

sub wait_for_timeout {
    my $self = shift;
    $self->{wait_for_timeout} = WAIT_FOR_TIMEOUT
	unless defined $self->{wait_for_timeout};
    my $d = $self->{wait_for_timeout};
    $self->{wait_for_timeout} = shift if @_;
    return $d;
}

=head1 TAGS

=head1 VIRTUAL PRIVATE CLOUDS

=head1 Elastic Load Balancers (ELB)

=head1 AWS SECURITY TOKENS


=head1 AUTOSCALING GROUPS
=head2 LAUNCH CONFIGURATIONS

# ------------------------------------------------------------------------------------------

=head1 INTERNAL METHODS

These methods are used internally and are listed here without
documentation (yet).

=head2 $underscore_name = $ec2->canonicalize($mixedCaseName)

=cut

sub canonicalize {
    my $self = shift;
    my $name = shift;
    while ($name =~ /\w[A-Z.]/) {
	$name    =~ s/([a-zA-Z])\.?([A-Z])/\L$1_$2/g or last;
    }
    return $name =~ /^-/ ? lc $name : '-'.lc $name;
}

sub uncanonicalize {
    my $self = shift;
    my $name = shift;
    $name    =~ s/_([a-z])/\U$1/g;
    return $name;
}

=head2 $instance_id = $ec2->instance_parm(@args)

=cut

sub instance_parm {
    my $self = shift;
    my %args;
    if ($_[0] =~ /^-/) {
	%args = @_; 
    } elsif (@_ > 1) {
	%args = (-instance_id => [@_]);
    } else {
	%args = (-instance_id => shift);
    }
    my $id = $args{-instance_id};
    return ref $id && ref $id eq 'ARRAY' ? @$id : $id;
}

=head2 @arguments = $ec2->value_parm(ParameterName => \%args)

=cut

sub value_parm {
    my $self = shift;
    my ($argname,$args) = @_;
    my $name = $self->canonicalize($argname);
    return unless exists $args->{$name} || exists $args->{"-$argname"};
    my $val = $args->{$name} || $args->{"-$argname"};
    return ("$argname.Value"=>$val);
}

=head2 @arguments = $ec2->single_parm(ParameterName => \%args)

=cut

sub single_parm {
    my $self = shift;
    my ($argname,$args) = @_;
    my $name = $self->canonicalize($argname);
    my $val  = $args->{$name} || $args->{"-$argname"};
    defined $val or return;
    my $v = ref $val  && ref $val eq 'ARRAY' ? $val->[0] : $val;
    return ($argname=>$v);
}

=head2 @parameters = $ec2->prefix_parm($prefix, ParameterName => \%args)

=cut

sub prefix_parm {
    my $self = shift;
    my ($prefix,$argname,$args) = @_;
    my $name = $self->canonicalize($argname);
    my $val  = $args->{$name} || $args->{"-$argname"};
    defined $val or return;
    my $v = ref $val  && ref $val eq 'ARRAY' ? $val->[0] : $val;
    return ("$prefix.$argname"=>$v);
}

=head2 @parameters = $ec2->member_list_parm(ParameterName => \%args)

=cut

sub member_list_parm {
    my $self = shift;
    my ($argname,$args) = @_;
    my $name = $self->canonicalize($argname);

    my @params;
    if (my $a = $args->{$name}||$args->{"-$argname"}) {
        my $c = 1;
        for (ref $a && ref $a eq 'ARRAY' ? @$a : $a) {
            push @params,("$argname.member.".$c++ => $_);
        }
    }
    return @params;
}

=head2 @arguments = $ec2->list_parm(ParameterName => \%args)

=cut

sub list_parm {
    my $self = shift;
    my ($argname,$args) = @_;
    my $name = $self->canonicalize($argname);

    my @params;
    if (my $a = $args->{$name}||$args->{"-$argname"}) {
	my $c = 1;
	for (ref $a && ref $a eq 'ARRAY' ? @$a : $a) {
	    push @params,("$argname.".$c++ => $_);
	}
    }

    return @params;
}

=head2 @arguments = $ec2->filter_parm(\%args)

=cut

sub filter_parm {
    my $self = shift;
    my $args = shift;
    return $self->key_value_parameters('Filter','Name','Value',$args);
}

=head2 @arguments = $ec2->key_value_parameters($param_name,$keyname,$valuename,\%args,$skip_undef_values)

=cut

sub key_value_parameters {
    my $self = shift;
    # e.g. 'Filter', 'Name','Value',{-filter=>{a=>b}}
    my ($parameter_name,$keyname,$valuename,$args,$skip_undef_values) = @_;  
    my $arg_name     = $self->canonicalize($parameter_name);
    
    my @params;
    if (my $a = $args->{$arg_name}||$args->{"-$parameter_name"}) {
	my $c = 1;
	if (ref $a && ref $a eq 'HASH') {
	    while (my ($name,$value) = each %$a) {
		push @params,("$parameter_name.$c.$keyname"   => $name);
		if (ref $value && ref $value eq 'ARRAY') {
		    for (my $m=1;$m<=@$value;$m++) {
			push @params,("$parameter_name.$c.$valuename.$m" => $value->[$m-1])
		    }
		} else {
		    push @params,("$parameter_name.$c.$valuename" => $value)
			unless !defined $value && $skip_undef_values;
		}
		$c++;
	    }
	} else {
	    for (ref $a ? @$a : $a) {
		my ($name,$value) = /([^=]+)\s*=\s*(.+)/;
		push @params,("$parameter_name.$c.$keyname"   => $name);
		push @params,("$parameter_name.$c.$valuename" => $value)
		    unless !defined $value && $skip_undef_values;
		$c++;
	    }
	}
    }

    return @params;
}

=head2 @arguments = $ec2->launch_perm_parm($prefix,$suffix,$value)

=cut

sub launch_perm_parm {
    my $self = shift;
    my ($prefix,$suffix,$value) = @_;
    return unless defined $value;
    $self->_perm_parm('LaunchPermission',$prefix,$suffix,$value);
}

sub create_volume_perm_parm {
    my $self = shift;
    my ($prefix,$suffix,$value) = @_;
    return unless defined $value;
    $self->_perm_parm('CreateVolumePermission',$prefix,$suffix,$value);
}

sub _perm_parm {
    my $self = shift;
    my ($base,$prefix,$suffix,$value) = @_;
    return unless defined $value;
    my @list = ref $value && ref $value eq 'ARRAY' ? @$value : $value;
    my $c = 1;
    my @param;
    for my $v (@list) {
	push @param,("$base.$prefix.$c.$suffix" => $v);
	$c++;
    }
    return @param;
}

=head2 @arguments = $ec2->iam_parm($args)

=cut

sub iam_parm {
    my $self = shift;
    my $args = shift;
    my @p;
    push @p,('IamInstanceProfile.Arn'  => $args->{-iam_arn})             if $args->{-iam_arn};
    push @p,('IamInstanceProfile.Name' => $args->{-iam_name})            if $args->{-iam_name};
    return @p;
}

=head2 @arguments = $ec2->block_device_parm($block_device_mapping_string)

=cut

sub block_device_parm {
    my $self    = shift;
    my $devlist = shift or return;

    my @dev     = ref $devlist && ref $devlist eq 'ARRAY' ? @$devlist : $devlist;

    my @p;
    my $c = 1;
    for my $d (@dev) {
	$d =~ /^([^=]+)=([^=]+)$/ or croak "block device mapping must be in format /dev/sdXX=device-name";

	my ($devicename,$blockdevice) = ($1,$2);
	push @p,("BlockDeviceMapping.$c.DeviceName"=>$devicename);

	if ($blockdevice =~ /^vol-/) {  # this is a volume, and not a snapshot
	    my ($volume,$delete_on_term) = split ':',$blockdevice;
	    push @p,("BlockDeviceMapping.$c.Ebs.VolumeId" => $volume);
	    push @p,("BlockDeviceMapping.$c.Ebs.DeleteOnTermination"=>$delete_on_term) 
		if defined $delete_on_term  && $delete_on_term=~/^(true|false|1|0)$/
	}
	elsif ($blockdevice eq 'none') {
	    push @p,("BlockDeviceMapping.$c.NoDevice" => '');
	} elsif ($blockdevice =~ /^ephemeral\d$/) {
	    push @p,("BlockDeviceMapping.$c.VirtualName"=>$blockdevice);
	} else {
	    my ($snapshot,$size,$delete_on_term,$vtype,$iops) = split ':',$blockdevice;

	    # Workaround for apparent bug in 2012-12-01 API; instances will crash without volume size
	    # even if a snapshot ID is provided
	    if ($snapshot) {
		$size ||= eval{$self->describe_snapshots($snapshot)->volumeSize};
		push @p,("BlockDeviceMapping.$c.Ebs.SnapshotId" =>$snapshot);
	    }

	    push @p,("BlockDeviceMapping.$c.Ebs.VolumeSize" =>$size)                    if $size;
	    push @p,("BlockDeviceMapping.$c.Ebs.DeleteOnTermination"=>$delete_on_term) 
		if defined $delete_on_term  && $delete_on_term=~/^(true|false|1|0)$/;
	    push @p,("BlockDeviceMapping.$c.Ebs.VolumeType"=>$vtype)                    if $vtype;
	    push @p,("BlockDeviceMapping.$c.Ebs.Iops"=>$iops)                           if $iops;
	}
	$c++;
    }
    return @p;
}

# ['eth0=eni-123456','eth1=192.168.2.1,192.168.3.1,192.168.4.1:subnet-12345:sg-12345:true:My Weird Network']
# form 1: ethX=network device id
# form 2: ethX=primary_address,secondary_address1,secondary_address2...:subnetId:securityGroupId:deleteOnTermination:description
# form 3: ethX=primary_address,secondary_address_count:subnetId:securityGroupId:deleteOnTermination:description
sub network_interface_parm {
    my $self = shift;
    my $args    = shift;
    my $devlist = $args->{-network_interfaces} or return;
    my @dev     = ref $devlist && ref $devlist eq 'ARRAY' ? @$devlist : $devlist;

    my @p;
    my $c = 0;
    for my $d (@dev) {
	$d =~ /^eth(\d+)\s*=\s*([^=]+)$/ or croak "network device mapping must be in format ethX=option-string";

	my ($device_index,$device_options) = ($1,$2);
	push @p,("NetworkInterface.$c.DeviceIndex" => $device_index);
	my @options = split ':',$device_options;
	if (@options == 1) {
	    push @p,("NetworkInterface.$c.NetworkInterfaceId" => $options[0]);
	} 
	else {
	    my ($ip_addresses,$subnet_id,$security_group_id,$delete_on_termination,$description) = @options;
	    my @addresses = split /\s*,\s*/,$ip_addresses;
	    for (my $a = 0; $a < @addresses; $a++) {
		if ($addresses[$a] =~ /^\d+\.\d+\.\d+\.\d+$/ ) {
		    push @p,("NetworkInterface.$c.PrivateIpAddresses.$a.PrivateIpAddress" => $addresses[$a]);
		    push @p,("NetworkInterface.$c.PrivateIpAddresses.$a.Primary"          => $a == 0 ? 'true' : 'false');
		}
		elsif ($addresses[$a] =~ /^\d+$/ && $a > 0) {
		    push @p,("NetworkInterface.$c.SecondaryPrivateIpAddressCount"        => $addresses[$a]);
		}
	    }
	    my @sgs = split ',',$security_group_id;
	    for (my $i=0;$i<@sgs;$i++) {
		push @p,("NetworkInterface.$c.SecurityGroupId.$i" => $sgs[$i]);
	    }

	    push @p,("NetworkInterface.$c.SubnetId"              => $subnet_id)             if length $subnet_id;
	    push @p,("NetworkInterface.$c.DeleteOnTermination"   => $delete_on_termination) if length $delete_on_termination;
	    push @p,("NetworkInterface.$c.Description"           => $description)           if length $description;
	}
	$c++;
    }
    return @p;
}

sub boolean_parm {
    my $self = shift;
    my ($argname,$args) = @_;
    my $name = $self->canonicalize($argname);
    return unless exists $args->{$name} || exists $args->{$argname};
    my $val = $args->{$name} || $args->{$argname};
    return ($argname => $val ? 'true' : 'false');
}

=head2 $version = $ec2->version()

API version.

=cut

sub version  { 
    my $self = shift;
    return $self->{version} ||=  '2012-12-01';
}

=head2 $ts = $ec2->timestamp

=cut

sub timestamp {
    return strftime("%Y-%m-%dT%H:%M:%SZ",gmtime);
}


=head2 $ua = $ec2->ua

LWP::UserAgent object.

=cut

sub ua {
    my $self = shift;
    return $self->{ua} ||= LWP::UserAgent->new;
}

=head2 @obj = $ec2->call($action,@param);

Make a call to Amazon using $action and the passed arguments, and
return a list of objects.

=cut

sub call {
    my $self    = shift;
    my $response  = $self->make_request(@_);

    my $sleep_time = 2;
    while ($response->decoded_content =~ 'RequestLimitExceeded') {
        last if ($sleep_time > 64); # wait at most 64 seconds
        sleep $sleep_time;
        $sleep_time *= 2;
        $response  = $self->make_request(@_);
    }
    unless ($response->is_success) {
	my $content = $response->decoded_content;
	my $error;
	if ($content =~ /<Response>/) {
	    $error = VM::EC2::Dispatch->create_error_object($response->decoded_content,$self,$_[0]);
	} else {
	    my $code = $response->status_line;
	    my $msg  = $response->decoded_content;
	    $error = VM::EC2::Error->new({Code=>$code,Message=>"$msg from API call '$_[0]')"},$self);
	}
	$self->error($error);
	carp  "$error" if $self->print_error;
	croak "$error" if $self->raise_error;
	return;
    }

    $self->error(undef);
    my @obj = VM::EC2::Dispatch->response2objects($response,$self);

    # slight trick here so that we return one object in response to
    # describe_images(-image_id=>'foo'), rather than the number "1"
    if (!wantarray) { # scalar context
	return $obj[0] if @obj == 1;
	return         if @obj == 0;
	return @obj;
    } else {
	return @obj;
    }
}

sub sts_call {
    my $self = shift;
    local $self->{endpoint} = 'https://sts.amazonaws.com';
    local $self->{version}  = '2011-06-15';
    $self->call(@_);
}

sub elb_call {
    my $self = shift;
    (my $endpoint = $self->{endpoint}) =~ s/ec2/elasticloadbalancing/;
    local $self->{endpoint} = $endpoint;
    local $self->{version}  = '2012-06-01';
    $self->call(@_);
}

sub asg_call {
    my $self = shift;
    (my $endpoint = $self->{endpoint}) =~ s/ec2/autoscaling/;
    local $self->{endpoint} = $endpoint;
    local $self->{version}  = '2011-01-01';
    $self->call(@_);
}

=head2 $request = $ec2->make_request($action,@param);

Set up the signed HTTP::Request object.

=cut

sub make_request {
    my $self    = shift;
    my ($action,@args) = @_;
    my $request = $self->_sign(Action=>$action,@args);
    return $self->ua->request($request);
}

=head2 $request = $ec2->_sign(@args)

Create and sign an HTTP::Request.

=cut

# adapted from Jeff Kim's Net::Amazon::EC2 module
sub _sign {
    my $self    = shift;
    my @args    = @_;

    my $action = 'POST';
    my $host   = lc URI->new($self->endpoint)->host;
    my $path   = '/';

    my %sign_hash                = @args;
    $sign_hash{AWSAccessKeyId}   = $self->id;
    $sign_hash{Timestamp}        = $self->timestamp;
    $sign_hash{Version}          = $self->version;
    $sign_hash{SignatureVersion} = 2;
    $sign_hash{SignatureMethod}  = 'HmacSHA256';
    $sign_hash{SecurityToken}    = $self->security_token if $self->security_token;

    my @param;
    my @parameter_keys = sort keys %sign_hash;
    for my $p (@parameter_keys) {
	push @param,join '=',map {uri_escape($_,"^A-Za-z0-9\-_.~")} ($p,$sign_hash{$p});
    }
    my $to_sign = join("\n",
		       $action,$host,$path,join('&',@param));
    my $signature = encode_base64(hmac_sha256($to_sign,$self->secret),'');
    $sign_hash{Signature} = $signature;

    my $uri = URI->new($self->endpoint);
    $uri->query_form(\%sign_hash);

    return POST $self->endpoint,[%sign_hash];
}

=head2 @param = $ec2->args(ParamName=>@_)

Set up calls that take either method(-resource_id=>'foo') or method('foo').

=cut

sub args {
    my $self = shift;
    my $default_param_name = shift;
    return unless @_;
    return @_ if $_[0] =~ /^-/;
    return (-filter=>shift) if @_==1 && ref $_[0] && ref $_[0] eq 'HASH';
    return ($default_param_name => \@_);
}

=head1 OTHER INFORMATION

This section contains technical information that may be of interest to developers.

=head2 Signing and authentication protocol

This module uses Amazon AWS signing protocol version 2, as described at
http://docs.amazonwebservices.com/AWSEC2/latest/UserGuide/index.html?using-query-api.html.
It uses the HmacSHA256 signature method, which is the most secure
method currently available. For additional security, use "https" for
the communications endpoint:

  $ec2 = VM::EC2->new(-endpoint=>'https://ec2.amazonaws.com');

=head2 Subclassing VM::EC2 objects

To subclass VM::EC2 objects (or implement your own from scratch) you
will need to override the object dispatch mechanism. Fortunately this
is very easy. After "use VM::EC2" call
VM::EC2::Dispatch->register() one or more times:

 VM::EC2::Dispatch->register($call_name => $dispatch).

The first argument, $call_name, is name of the Amazon API call, such as "DescribeImages".

The second argument, $dispatch, instructs VM::EC2::Dispatch how to
create objects from the parsed XML. There are three possible syntaxes:

 1) A CODE references, such as an anonymous subroutine.

    In this case the code reference will be invoked to handle the 
    parsed XML returned from the request. The code will receive 
    two arguments consisting of the parsed
    content of the response, and the VM::EC2 object used to generate the
    request.

 2) A VM::EC2::Dispatch method name, optionally followed by its arguments
    delimited by commas. Example:

           "fetch_items,securityGroupInfo,VM::EC2::SecurityGroup"

    This tells Dispatch to invoke its fetch_items() method with
    the following arguments:

     $dispatch->fetch_items($parsed_xml,$ec2,'securityGroupInfo','VM::EC2::SecurityGroup')

    The fetch_items() method is used for responses in which a
    list of objects is embedded within a series of <item> tags.
    See L<VM::EC2::Dispatch> for more information.

    Other commonly-used methods are "fetch_one", and "boolean".

 3) A class name, such as 'MyVolume'

    In this case, class MyVolume is loaded and then its new() method
    is called with the four arguments ($parsed_xml,$ec2,$xmlns,$requestid),
    where $parsed_xml is the parsed XML response, $ec2 is the VM::EC2
    object that generated the request, $xmlns is the XML namespace
    of the XML response, and $requestid is the AWS-generated ID for the
    request. Only the first two arguments are really useful.

    I suggest you inherit from VM::EC2::Generic and use the inherited new()
    method to store the parsed XML object and other arguments.

Dispatch tries each of (1), (2) and (3), in order. This means that
class names cannot collide with method names.

The parsed content is the result of passing the raw XML through a
XML::Simple object created with:

 XML::Simple->new(ForceArray    => ['item'],
                  KeyAttr       => ['key'],
                  SuppressEmpty => undef);

In general, this will give you a hash of hashes. Any tag named 'item'
will be forced to point to an array reference, and any tag named "key"
will be flattened as described in the XML::Simple documentation.

A simple way to examine the raw parsed XML is to invoke any
VM::EC2::Generic's as_string() method:

 my ($i) = $ec2->describe_instances;
 print $i->as_string;

This will give you a Data::Dumper representation of the XML after it
has been parsed.

The suggested way to override the dispatch table is from within a
subclass of VM::EC2:
 
 package 'VM::EC2New';
 use base 'VM::EC2';
  sub new {
      my $self=shift;
      VM::EC2::Dispatch->register('call_name_1'=>\&subroutine1).
      VM::EC2::Dispatch->register('call_name_2'=>\&subroutine2).
      $self->SUPER::new(@_);
 }

See L<VM::EC2::Dispatch> for a working example of subclassing VM::EC2
and one of its object classes.

=head1 DEVELOPING

The git source for this library can be found at https://github.com/lstein/LibVM-EC2-Perl,
To contribute to development, please obtain a github account and then either:
 
 1) Fork a copy of the repository, make your changes against this repository, 
    and send a pull request to me to incorporate your changes.

 2) Contact me by email and ask for push privileges on the repository.

See http://help.github.com/ for help getting started.

=head1 SEE ALSO

L<Net::Amazon::EC2>
L<VM::EC2::Dispatch>
L<VM::EC2::Generic>
L<VM::EC2::BlockDevice>
L<VM::EC2::BlockDevice::Attachment>
L<VM::EC2::BlockDevice::EBS>
L<VM::EC2::BlockDevice::Mapping>
L<VM::EC2::BlockDevice::Mapping::EBS>
L<VM::EC2::Error>
L<VM::EC2::Generic>
L<VM::EC2::Group>
L<VM::EC2::Image>
L<VM::EC2::Instance>
L<VM::EC2::Instance::ConsoleOutput>
L<VM::EC2::Instance::Metadata>
L<VM::EC2::Instance::MonitoringState>
L<VM::EC2::Instance::PasswordData>
L<VM::EC2::Instance::Set>
L<VM::EC2::Instance::State>
L<VM::EC2::Instance::State::Change>
L<VM::EC2::Instance::State::Reason>
L<VM::EC2::KeyPair>
L<VM::EC2::Region>
L<VM::EC2::ReservationSet>
L<VM::EC2::ReservedInstance>
L<VM::EC2::ReservedInstance::Offering>
L<VM::EC2::SecurityGroup>
L<VM::EC2::Snapshot>
L<VM::EC2::Staging::Manager>
L<VM::EC2::Tag>
L<VM::EC2::Volume>

=head1 AUTHOR

Lincoln Stein E<lt>lincoln.stein@gmail.comE<gt>.

Copyright (c) 2011 Ontario Institute for Cancer Research

This package and its accompanying libraries is free software; you can
redistribute it and/or modify it under the terms of the GPL (either
version 1, or at your option, any later version) or the Artistic
License 2.0.  Refer to LICENSE for the full license text. In addition,
please see DISCLAIMER.txt for disclaimers of warranty.

=cut


1;
