package VM::EC2::Dispatch;

use strict;

use XML::Simple;
use URI::Escape;

=head1 NAME

VM::EC2::Dispatch - Create Perl objects from AWS XML requests

=head1 SYNOPSIS

  use VM::EC2;

  VM::EC2::Dispatch->register('DescribeRegions'=>\&mysub);

  VM::EC2::Dispatch->replace('DescribeRegions'=>'My::Type');
  
  sub mysub {
      my ($parsed_xml_object,$ec2) = @_;
      my $payload = $parsed_xml_object->{regionInfo}
      return My::Type->new($payload,$ec2);
  }

=head1 DESCRIPTION

This class handles turning the XML response to AWS requests into perl
objects. Only one method is likely to be useful to developers, the
replace() class method. This allows you to replace the handlers
used to map the response onto objects.

=head2 VM::EC2::Dispatch->replace($request_name => \&sub)

=head2 VM::EC2::Dispatch->replace($request_name => 'Class::Name')

=head2 VM::EC2::Dispatch->replace($request_name => 'method_name,arg1,arg2,...')

Before invoking a VM::EC2 request you wish to customize, call the
replace() method with two arguments. The first argument is the
name of the request you wish to customize, such as
"DescribeVolumes". The second argument is either a code reference, a
VM::EC2::Dispatch method name and arguments (separated by commas), or
a class name.

In the case of a code reference as the second argument, the subroutine
you provide will be invoked with four arguments consisting of the
parsed XML response, the VM::EC2 object, the XML namespace string from
the request, and the Amazon-assigned request ID. In practice, only the
first two arguments are useful.

In the case of a string containing a classname, the class will be
loaded if it needs to be, and then its new() method invoked as
follows:

  Your::Class->new($parsed_xml,$ec2,$xmlns,$requestid)

Your new() method should return one or more objects. It is suggested
that you subclass VM::EC2::Generic and use the inherited new() method
to store the parsed XML and EC2 object. See the code for
L<VM::EC2::AvailabilityRegion> for a simple template.

If the second argument is neither a code reference nor a classname, it
will be treated as a VM::EC2::Dispatch method name and its arguments,
separated by commas. The method will be invoked as follows:

 $dispatch->$method_name($raw_xml,$ec2,$arg1,$arg2,$arg3,...)

There are two methods currently defined for this purpose, boolean(),
and fetch_items(), which handle the preprocessing of several common
XML representations of EC2 data. Note that in this form, the RAW XML
is passed in, not the parsed data structure.

The parsed XML response is generated by the XML::Simple module using
these options:

  $parser = XML::Simple->new(ForceArray    => ['item', 'member'],
                             KeyAttr       => ['key'],
                             SuppressEmpty => undef);
  $parsed = $parser->XMLin($raw_xml)

In general, this will give you a hash of hashes. Any tag named 'item'
or 'member' will be forced to point to an array reference, and any tag
named "key" will be flattened as described in the XML::Simple
documentation.

A simple way to examine the raw parsed XML is to invoke any
VM::EC2::Object's as_string method:

 my ($i) = $ec2->describe_instances;
 print $i->as_string;

This will give you a Data::Dumper representation of the XML after it
has been parsed. Look at the calls to VM::EC2::Dispatch->register() in
the various VM/EC2/REST/*.pm modules for many examples of how this
works.

Note that the replace() method was called add_override() in previous
versions of this module. add_override() is recognized as an alias for
backward compatibility.

=head2 VM::EC2::Dispatch->register($request_name1 => \&sub1,$request_name2 => \&sub2,...)

Similar to replace() but if the request name is already registered
does not overwrite it. You may provide multiple request=>handler pairs.

=head1 OBJECT CREATION METHODS

The following methods perform simple pre-processing of the parsed XML
(a hash of hashes) before passing the modified data structure to the
designated object class. They are used as the second argument to
VM::EC2::Dispatch->register().

=cut
    ;

my $REGISTRATION = {};
VM::EC2::Dispatch->register(Error => 'VM::EC2::Error');
*add_override    = \&replace; # backward compatibility

# Not clear that you ever need to instantiate this object as it has
# no instance data.
sub new {
    my $class    = shift;
    my $self= bless {},ref $class || $class;
    return $self;
}

sub replace {
    my $self = shift;
    while (my ($request_name,$object_creator) = splice(@_,0,2)) {
	$REGISTRATION->{$request_name} = $object_creator;
    }
}

sub register {
    my $self = shift;
    while (my ($request_name,$object_creator) = splice(@_,0,2)) {
	$REGISTRATION->{$request_name} ||= $object_creator;
    }
}

# new way
sub content2objects {
    my $self = shift;
    my ($action,$content,$ec2) = @_;

    my $handler = $REGISTRATION->{$action} || 'VM::EC2::Generic';
    my ($method,@params) = split /,/,$handler;

    if (ref $handler eq 'CODE') {
	my $parsed = $self->new_xml_parser->XMLin($content);
	$handler->($parsed,$ec2,@{$parsed}{'xmlns','requestId'});
    }
    elsif ($self->can($method)) {
	return $self->$method($content,$ec2,@params);
    }
    else {
	load_module($handler);
	my $parser   = $self->new();
	$parser->parse($content,$ec2,$handler);
    }
}

# old way
sub response2objects {
    my $self     = shift;
    my ($response,$ec2) = @_;

    my $handler  = $self->class_from_response($response) or return;
    my $content  = $response->decoded_content;

    my ($method,@params) = split /,/,$handler;

    if (ref $handler eq 'CODE') {
	my $parsed = $self->new_xml_parser->XMLin($content);
	$handler->($parsed,$ec2,@{$parsed}{'xmlns','requestId'});
    }
    elsif ($self->can($method)) {
	return $self->$method($content,$ec2,@params);
    }
    else {
	load_module($handler);
	my $parser   = $self->new();
	$parser->parse($content,$ec2,$handler);
    }
}

sub class_from_response {
    my $self     = shift;
    my $response = shift;
    my ($action) = $response->request->content =~ /Action=([^&]+)/;
    $action      = uri_unescape($action);
    return $REGISTRATION->{$action} || 'VM::EC2::Generic';
}

sub parser { 
    my $self = shift;
    return $self->{xml_parser} ||=  $self->new_xml_parser;
}

sub parse {
    my $self    = shift;
    my ($content,$ec2,$class) = @_;
    $self       = $self->new unless ref $self;
    my $parsed  = $self->parser->XMLin($content);
    return $self->create_objects($parsed,$ec2,$class);
}

sub new_xml_parser {
    my $self  = shift;
    my $nokey = shift;
    return XML::Simple->new(ForceArray    => ['item', 'member'],
			    KeyAttr       => $nokey ? [] : ['key'],
			    SuppressEmpty => undef,
	);
}

=head2 $bool = $dispatch->boolean($raw_xml,$ec2,$tag)

This is used for XML responses like this:

 <DeleteVolumeResponse xmlns="http://ec2.amazonaws.com/doc/2011-05-15/">
    <requestId>59dbff89-35bd-4eac-99ed-be587EXAMPLE</requestId> 
    <return>true</return>
 </DeleteVolumeResponse>

It looks inside the structure for the tag named $tag ("return" if not
provided), and returns a true value if the contents equals "true".

Pass it to replace() like this:

  VM::EC2::Dispatch->replace(DeleteVolume => 'boolean,return';

or, since "return" is the default tag:

  VM::EC2::Dispatch->replace(DeleteVolume => 'boolean';

=cut

sub boolean {
    my $self = shift;
    my ($content,$ec2,$tag) = @_;
    my $parsed = $self->new_xml_parser()->XMLin($content);
    $tag ||= 'return';
    return $parsed->{$tag} eq 'true';
}

=head2 @list = $dispatch->elb_member_list($raw_xml,$ec2,$tag)

This is used for XML responses from the ELB API such as this:

 <DisableAvailabilityZonesForLoadBalancerResponse xmlns="http://elasticloadbalancing.amazonaws.com/doc/2011-11-15/">
   <DisableAvailabilityZonesForLoadBalancerResult>
     <AvailabilityZones>
       <member>us-west-2a</member>
       <member>us-west-2b</member>
     </AvailabilityZones>
   </DisableAvailabilityZonesForLoadBalancerResult>
   <ResponseMetadata>
     <RequestId>02eadcfc-fc38-11e1-a1bf-9de31EXAMPLE</RequestId>
   </ResponseMetadata>
 </DisableAvailabilityZonesForLoadBalancerResponse>

It looks inside the Result structure for the tag named $tag and returns the
list wrapped in member elements.  In this case the tag is 'AvailabilityZones'
and the return value would be:
( 'us-west-2a', 'us-west-2b' )

If $embedded_tag is passed, then it is used for XML responses such as this,
where the member list has an embedded tag:

 <RegisterInstancesWithLoadBalancerResponse xmlns="http://elasticloadbalancing.amazonaws.com/doc/2011-11-15/">
   <RegisterInstancesWithLoadBalancerResult>
     <Instances>
       <member>
         <InstanceId>i-12345678</InstanceId>
       </member>
       <member>
         <InstanceId>i-90abcdef</InstanceId>
       </member>
     </Instances>
   </RegisterInstancesWithLoadBalancerResult>
   <ResponseMetadata>
     <RequestId>f4f12596-fc3b-11e1-be5a-f71ecEXAMPLE</RequestId>
   </ResponseMetadata>
 </RegisterInstancesWithLoadBalancerResponse>

It looks inside the Result structure for the tag named $tag and returns the
list wrapped in a member element plus the embedded tag.  In this case the 
tag is 'Instances', the embedded tag is 'InstanceId' and the return value would
be: ( 'i-12345678', 'i-90abcdef' )

=cut

sub elb_member_list {
    my $self = shift;
    my ($content,$ec2,$tag,$embedded_tag) = @_;
    my $parsed = $self->new_xml_parser()->XMLin($content);
    my ($result_key) = grep /Result$/,keys %$parsed;
    return $embedded_tag ? map { $_->{$embedded_tag} } @{$parsed->{$result_key}{$tag}{member}} :
                           @{$parsed->{$result_key}{$tag}{member}};
}

# identical to fetch_one, except looks inside the *Result tag that ELB API calls
# return
sub elb_fetch_one {
    my $self = shift;
    my ($content,$ec2,$tag,$class,$nokey) = @_; 
    load_module($class);
    my $parser = $self->new_xml_parser($nokey);
    my $parsed = $parser->XMLin($content);
    my ($result_key) = grep /Result$/,keys %$parsed;
    my $obj    = $parsed->{$result_key}{$tag} or return;
    return $class->new($obj,$ec2,@{$parsed}{'xmlns','requestId'});
}

sub fetch_one {
    my $self = shift;
    my ($content,$ec2,$tag,$class,$nokey) = @_;
    load_module($class);
    my $parser = $self->new_xml_parser($nokey);
    my $parsed = $parser->XMLin($content);
    my $obj    = $parsed->{$tag} or return;
    return $class->new($obj,$ec2,@{$parsed}{'xmlns','requestId'});
}

=head2 @objects = $dispatch->fetch_items($raw_xml,$ec2,$container_tag,$object_class,$nokey)

This is used for XML responses like this:

 <DescribeKeyPairsResponse xmlns="http://ec2.amazonaws.com/doc/2011-05-15/">
    <requestId>59dbff89-35bd-4eac-99ed-be587EXAMPLE</requestId> 
    <keySet>
      <item>
         <keyName>gsg-keypair</keyName>
         <keyFingerprint>
         1f:51:ae:28:bf:89:e9:d8:1f:25:5d:37:2d:7d:b8:ca:9f:f5:f1:6f
         </keyFingerprint>
      </item>
      <item>
         <keyName>default-keypair</keyName>
         <keyFingerprint>
         0a:93:bb:e8:c2:89:e9:d8:1f:42:5d:37:1d:8d:b8:0a:88:f1:f1:1a
         </keyFingerprint>
      </item>
   </keySet>
 </DescribeKeyPairsResponse>

It looks inside the structure for the tag named $container_tag, pulls
out the items that are stored under <item> and then passes the parsed
contents to $object_class->new(). The optional $nokey argument is used
to suppress XML::Simple's default flattening behavior turning tags
named "key" into hash keys.

Pass it to replace() like this:

  VM::EC2::Dispatch->replace(DescribeVolumes => 'fetch_items,volumeSet,VM::EC2::Volume')

=cut

sub fetch_items {
    my $self = shift;
    my ($content,$ec2,$tag,$class,$nokey) = @_;
    load_module($class);
    my $parser = $self->new_xml_parser($nokey);
    my $parsed = $parser->XMLin($content);
    my $list   = $parsed->{$tag}{item} or return;
    return map {$class->new($_,$ec2,@{$parsed}{'xmlns','requestId'})} @$list;
}

=head2 @objects = $dispatch->fetch_members($raw_xml,$ec2,$container_tag,$object_class,$nokey)

Used for XML responses from ELB API calls which contain a key that is the name
of the API call with 'Result' appended.  All these XML responses contain
'member' as the item delimter instead of 'item'

=cut

sub fetch_members {
    my $self = shift;
    my ($content,$ec2,$tag,$class,$nokey) = @_;
    load_module($class);
    my $parser = $self->new_xml_parser($nokey);
    my $parsed = $parser->XMLin($content);
    my ($result_key) = grep /Result$/,keys %$parsed;
    my $list   = $parsed->{$result_key}{$tag}{member} or return;
    return map {$class->new($_,$ec2,@{$parsed}{'xmlns','requestId'})} @$list;
}

=head2 @objects = $dispatch->fetch_items_iterator($raw_xml,$ec2,$container_tag,$object_class,$token_name)

This is used for requests that have a -max_results argument. In this
case, the response will have a nextToken field, which can be used to
fetch the "next page" of results.

The $token_name is some unique identifying token. It will be turned
into two temporary EC2 instance variables, one named
"${token_name}_token", which contains the nextToken value, and the
other "${token_name}_stop", which flags the caller that no more
results will be forthcoming.

This must all be coordinated with the request subroutine. See how
describe_instance_status() and describe_spot_price_history() do it.

=cut

sub fetch_items_iterator {
    my $self = shift;
    my ($content,$ec2,$tag,$class,$base_name) = @_;
    my $token = "${base_name}_token";
    my $stop  = "${base_name}_stop";

    load_module($class);
    my $parser = $self->new_xml_parser();
    my $parsed = $parser->XMLin($content);
    my $list   = $parsed->{$tag}{item} or return;

    if ($ec2->{$token} && !$parsed->{nextToken}) {
	delete $ec2->{$token};
	$ec2->{$stop}++;
    } else {
	$ec2->{$token} = $parsed->{nextToken};
    }
    return map {$class->new($_,$ec2,@{$parsed}{'xmlns','requestId'})} @$list;
}

sub create_objects {
    my $self   = shift;
    my ($parsed,$ec2,$class) = @_;
    return $class->new($parsed,$ec2,@{$parsed}{'xmlns','requestId'});
}

sub create_error_object {
    my $self = shift;
    my ($content,$ec2,$API_call) = @_;
    my $class   = $REGISTRATION->{Error};
    eval "require $class; 1" || die $@ unless $class->can('new');
    my $parsed = $self->new_xml_parser->XMLin($content);
    if (defined $API_call) {
	$parsed->{Errors}{Error}{Message} =~ s/\.$//;
	$parsed->{Errors}{Error}{Message} .= ", at API call '$API_call'";
    }
    return $class->new($parsed->{Errors}{Error},$ec2,@{$parsed}{'xmlns','requestId'});
}

# not a method!
sub load_module {
    my $class = shift;
    eval "require $class; 1" || die $@ unless $class->can('new');
}

=head1 EXAMPLE OF USING OVERRIDE TO SUBCLASS VM::EC2::Volume

The author decided that a volume object should not be able to delete
itself; you disagree with that decision. Let's subclass
VM::EC2::Volume to add a delete() method.

First subclass the VM::EC2::Volume class:

 package MyVolume;
 use base 'VM::EC2::Volume';

 sub delete {
    my $self = shift;
    $self->ec2->delete_volume($self);
 }

Now subclass VM::EC2 to add the appropriate overrides to the new() method:

 package MyEC2;
 use base 'VM::EC2';

 sub new {
   my $class = shift;
   VM::EC2::Dispatch->replace(CreateVolume   =>'MyVolume');
   VM::EC2::Dispatch->replace(DescribeVolumes=>'fetch_items,volumeSet,MyVolume');
   return $class->SUPER::new(@_);
 }

Now we can test it out:

 use MyEC2;
 # find all volumes that are "available" and not in-use
 my @vol = $ec2->describe_volumes({status=>'available'});
 for my $vol (@vol) { 
    $vol->delete && print "$vol deleted\n" 
 }
 
=head1 SEE ALSO

L<VM::EC2>
L<VM::EC2::Object>
L<VM::EC2::Generic>
L<VM::EC2::BlockDevice>
L<VM::EC2::BlockDevice::Attachment>
L<VM::EC2::BlockDevice::Mapping>
L<VM::EC2::BlockDevice::Mapping::EBS>
L<VM::EC2::Error>
L<VM::EC2::Generic>
L<VM::EC2::Group>
L<VM::EC2::Image>
L<VM::EC2::Instance>
L<VM::EC2::Instance::ConsoleOutput>
L<VM::EC2::Instance::Set>
L<VM::EC2::Instance::State>
L<VM::EC2::Instance::State::Change>
L<VM::EC2::Instance::State::Reason>
L<VM::EC2::Region>
L<VM::EC2::ReservationSet>
L<VM::EC2::SecurityGroup>
L<VM::EC2::Snapshot>
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

