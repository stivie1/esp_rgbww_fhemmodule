##############################################
# $Id: 32_LedController.pm 0 2016-05-01 12:00:00Z herrmannj $

# TODO
# I'm fully aware of this http://xkcd.com/1695/
#
# * timer driven updates - InternalTimer(gettimeofday()+0.2, LedController_...
#   -> start as soon as an animation is started
#   -> stop when h,s,v have not changed for one timer cycle (we don't want to waste cycles when the lights are static)
#   -> use the blocking update method in the feature_stop branch, check for issues with using blocking and non blocking http calls
#

# versions
# 00 POC
# 01 initial working version
# 02 stabilized, transitions working, initial use of attrs

# verbose level
# 0: quit
# 1: error
# 2: warning
# 3: user command
# 4: 1st technical level (detailed internal reporting)
# 5: 2nd technical level (full internal reporting)

package main;

use strict;
use warnings;

use DevIo;
use Time::HiRes;
use Time::HiRes qw(usleep nanosleep);
use Time::HiRes qw(time);
use JSON;
use JSON::XS;
use Data::Dumper;
use SetExtensions;

$Data::Dumper::Indent   = 1;
$Data::Dumper::Sortkeys = 1;

sub LedController_Initialize(@) {

  my ($hash) = @_;

  $hash->{DefFn}      = 'LedController_Define';
  $hash->{UndefFn}    = 'LedController_Undef';
  $hash->{ShutdownFn} = 'LedController_Undef';
  $hash->{SetFn}      = 'LedController_Set';
  $hash->{GetFn}      = 'LedController_Get';
  $hash->{ReadyFn}    = 'LedController_Ready';
  $hash->{AttrFn}     = 'LedController_Attr';
  $hash->{NotifyFn}   = 'LedController_Notify';
  $hash->{ReadFn}     = 'LedController_Read';
  $hash->{AttrList}   = "defaultRamp defaultColor defaultHue defaultSat defaultVal colorTemp slaves" . " $readingFnAttributes";
  require "HttpUtils.pm";

  # initialize message bus and process framework
  #require "Broker.pm";
  #my %service = (
  #  'functions' => {
  #    'connectFn' => 'LedControllerService_Initialize'
  #  }
  #);
  #'LedController_InitializeChild'
  #Broker::RESPONSEService('LedControllerService', \%service);

  return undef;
}

sub LedController_Define($$) {

  my ( $hash, $def ) = @_;
  my @a = split( "[ \t][ \t]*", $def );

  return "wrong syntax: define <name> LedController <ip> [<port>]" if ( @a != 3 && @a != 4 );

  my $name = $a[0];
  $hash->{IP} = $a[2];
  $hash->{PORT} = defined( $a[3] ) ? $a[3] : 9090;

  @{ $hash->{helper}->{cmdQueue} } = ();
  $hash->{helper}->{isBusy} = 0;

  # TODO remove, fixeg loglevel 5 only for debugging
  #$attr{$hash->{NAME}}{verbose} = 5;
  LedController_GetInfo($hash);
  LedController_GetConfig($hash);
  $hash->{helper}->{oldVal} = 100;
  $hash->{DeviceName} = "$hash->{IP}:$hash->{PORT}";

  DevIo_OpenDev( $hash, 0, "LedController_Init", "LedController_Connect" );
}

sub LedController_Undef(@) {
  return undef;
}

sub LedController_Init(@) {
  my ($hash) = @_;
  $hash->{LAST_RECV} = time();
  LedController_Set( $hash, $hash->{NAME}, "config", "config-general-device_name", $hash->{NAME} );
  LedController_GetConfig($hash);
  LedController_GetInfo($hash);
  LedController_GetCurrentColor($hash);
  LedController_QueueIntervalUpdate($hash);
  return undef;
}

sub LedController_Connect($$) {
  my ( $hash, $err ) = @_;
  my $name = $hash->{NAME};

  if ($err) {
    Log3 $name, 4, "LedController ($name) - unable to connect to LedController: $err";
  }
}

sub LedController_QueueIntervalUpdate($;$) {
  my ( $hash, $time ) = @_;

  # remove old timer (we might just want to reset it)
  RemoveInternalTimer( $hash, "LedController_Check" );
  InternalTimer( time() + 10, "LedController_Check", $hash, 0 );
}

sub LedController_Check($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  return if ( !LedController_CheckConnection($hash) );

  # device alive, keep bugging it
  LedController_QueueIntervalUpdate($hash);
}

sub LedController_CheckConnection($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  if ( $hash->{STATE} eq "disconnected" ) {

    # we are already disconnected
    return 0;
  }

  my $lastRecvDiff = ( time() - $hash->{LAST_RECV} );

  # the controller should send keep alive every 60 seconds
  if ( $lastRecvDiff > 70 ) {
    Log3 $name, 3, "LedController_CheckConnection: Connection lost! Last data received $lastRecvDiff s ago";
    DevIo_Disconnected($hash);
    return 0;
  }
  Log3 $name, 4, "LedController_CheckConnection: Connection still alive. Last data received $lastRecvDiff s ago";

  return 1;
}

sub LedController_Ready($) {
  my ($hash) = @_;

  #Log3 $hash->{NAME}, 3, "LedController_Ready";

  return undef if IsDisabled( $hash->{NAME} );

  return DevIo_OpenDev( $hash, 1, "LedController_Init", "LedController_Connect" ) if ( $hash->{STATE} eq "disconnected" );
  return undef;
}

sub LedController_Read($) {
  my ($hash) = @_;
  my $name   = $hash->{NAME};
  my $now    = time();

  my $data = DevIo_SimpleRead($hash);
  return if ( not defined($data) );

  my $buffer = '';
  Log3( $name, 5, "LedController_ProcessRead" );

  #include previous partial message
  if ( defined( $hash->{PARTIAL} ) && $hash->{PARTIAL} ) {
    Log3( $name, 5, "LedController_ProcessRead: PARTIAL: " . $hash->{PARTIAL} );
    $buffer = $hash->{PARTIAL};
  }
  else {
    Log3( $name, 5, "No PARTIAL buffer" );
  }

  Log3( $name, 5, "LedController_ProcessRead: Incoming data: " . $data );

  $buffer = $buffer . $data;
  Log3( $name, 5, "LedController_ProcessRead: Current processing buffer (PARTIAL + incoming data): " . $buffer );

  my ( $msg, $tail ) = LedController_ParseMsg( $hash, $buffer );

  #processes all complete messages
  while ($msg) {
    Log3( $name, 5, "LedController_ProcessRead: Decoding JSON message. Length: " . length($msg) . " Content: " . $msg );
    my $obj = JSON->new->utf8(0)->decode($msg);

    if ( $obj->{method} eq "hsv_event" ) {
      LedController_UpdateReadingsHsv( $hash, $obj->{params}{h}, $obj->{params}{s}, $obj->{params}{v}, $obj->{params}{ct} );
    }
    elsif ( $obj->{method} eq "raw_event" ) {
      LedController_UpdateReadingsRaw( $hash, $obj->{params}{r}, $obj->{params}{g}, $obj->{params}{b}, $obj->{params}{cw}, $obj->{params}{ww} );
    }
    elsif ( $obj->{method} eq "transition_finished" ) {
      readingsSingleUpdate( $hash, "tranisitionFinished", $obj->{params}{name}, 1 );
    }
    elsif ( $obj->{method} eq "keep_alive" ) {
      $hash->{LAST_RECV} = $now;
    }
    elsif ( $obj->{method} eq "clock_slave_status" ) {
      readingsBeginUpdate($hash);
      readingsBulkUpdate( $hash, 'clockSlaveOffset',     $obj->{params}{offset} );
      readingsBulkUpdate( $hash, 'clockCurrentInterval', $obj->{params}{current_interval} );
      readingsEndUpdate( $hash, 1 );
    }
    else {
      Log3( $name, 3, "LedController_ProcessRead: Unknown message type: " . $obj->{method} );
    }
    ( $msg, $tail ) = LedController_ParseMsg( $hash, $tail );
  }
  $hash->{PARTIAL} = $tail;
  Log3( $name, 5, "LedController_ProcessRead: Tail: " . $tail );
  Log3( $name, 5, "LedController_ProcessRead: PARTIAL: " . $hash->{PARTIAL} );
  return;
}

#Parses a given string and returns ($msg,$tail). If the string contains a complete message
#(equal number of curly brackets) the return value $msg will contain this message. The
#remaining string is return in form of the $tail variable.
sub LedController_ParseMsg($$) {
  my ( $hash, $buffer ) = @_;
  my $name  = $hash->{NAME};
  my $open  = 0;
  my $close = 0;
  my $msg   = '';
  my $tail  = '';
  if ($buffer) {
    foreach my $c ( split //, $buffer ) {
      if ( $open == $close && $open > 0 ) {
        $tail .= $c;
      }
      elsif ( ( $open == $close ) && ( $c ne '{' ) ) {
        Log3( $name, 3, "LedController_ParseMsg: Garbage character before message: " . $c );
      }
      else {
        if ( $c eq '{' ) {
          $open++;
        }
        elsif ( $c eq '}' ) {
          $close++;
        }
        $msg .= $c;
      }
    }
    if ( $open != $close ) {
      $tail = $msg;
      $msg  = '';
    }
  }
  return ( $msg, $tail );
}

sub LedController_Get(@) {
  my ( $hash, $name, $cmd, @args ) = @_;
  my $cnt = @args;

  if ( $cmd eq 'config' ) {
    LedController_GetConfig($hash);
  }
  elsif ( $cmd eq 'info' ) {
    LedController_GetInfo($hash);
  }
  elsif ( $cmd eq 'update' ) {
    LedController_GetCurrentColor($hash);
  }
  else {
    return "Unknown argument $cmd, choose one of config update info";
  }

  return undef;
}

sub LedController_Set(@) {
  my ( $hash, $name, $cmd, @args ) = @_;
  my $forwardToSlaves = 0;

  # $colorTemp : Color temperature in Kelvin (K). Can be set in attr. Default 2700K.
  # Note: rangeCheck is performed in attr method, so a simple AttrVal with 2700 as default value is enough here.
  my $colorTemp = AttrVal( $hash->{NAME}, 'colorTemp', 2700 );

  #Log3( $hash, 3, "$hash->{NAME} (Set) called with $cmd, busy flag is $hash->{helper}->{isBusy}\n name is $name, args " . Dumper(@args) );

  my ( $argsError, $fadeTime, $fadeSpeed, $doQueue, $direction, $doRequeue, $fadeName, $transitionType, $channels );
  if ( $cmd ne "?" ) {
    my %argCmds = ( 'on' => 0, 'off' => 0, 'toggle' => 0, 'blink' => 0, 'pause' => 0, 'skip' => 0, 'continue' => 0, 'stop' => 0 );
    my $argsOffset = 1;
    $argsOffset = $argCmds{$cmd} if ( exists $argCmds{$cmd} );
    ( $argsError, $fadeTime, $fadeSpeed, $doQueue, $direction, $doRequeue, $fadeName, $transitionType, $channels ) =
      LedController_ArgsHelper( $hash, $argsOffset, @args );
    if ( !defined($fadeTime) && ( $cmd ne 'blink' ) ) {
      $fadeTime = AttrVal( $hash->{NAME}, 'defaultRamp', 0 );
    }
    if ( defined($fadeSpeed) && ( $cmd eq 'blink' ) ) {
      $argsError = "Fade speed parameter cannot be used with command $cmd";
    }
  }

  return $argsError if defined($argsError);

  if ( $cmd eq 'hsv' ) {

    # expected args: <hue:0-360>,<sat:0-100>,<val:0-100>
    # HSV color values --> $hue, $sat and $val are split from arg1
    my ( $hue, $sat, $val ) = split ',', $args[0];

    $hue = undef if ( length($hue) == 0 );
    $sat = undef if ( length($sat) == 0 );
    $val = undef if ( length($val) == 0 );

    if ( !defined($hue) && !defined($sat) && !defined($val) ) {
      my $msg = "$hash->{NAME} at least one of HUE, SAT or VAL must be set";
      Log3( $hash, 3, $msg );
      return $msg;
    }
    if ( defined($hue) && !LedController_rangeCheck( $hue, 0, 360 ) ) {
      my $msg = "$hash->{NAME} HUE must be a number from 0-360";
      Log3( $hash, 3, $msg );
      return $msg;
    }
    if ( ( length($sat) > 0 ) && !LedController_rangeCheck( $sat, 0, 100 ) ) {
      my $msg = "$hash->{NAME} SAT must be a number from 0-100";
      Log3( $hash, 3, $msg );
      return $msg;
    }
    if ( ( length($val) > 0 ) && !LedController_rangeCheck( $val, 0, 100 ) ) {
      my $msg = "$hash->{NAME} VAL must be a number from 0-100";
      Log3( $hash, 3, $msg );
      return $msg;
    }

    LedController_SetHSVColor( $hash, $hue, $sat, $val, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'rgb' ) {

    # the native mode of operation for those controllers is HSV
    # I am converting RGB into HSV and then set that
    # This is to make use of the internal color compensation of the controller

    # sanity check, is string in required format?
    if ( !defined( $args[0] ) || $args[0] !~ /^[0-9A-Fa-f]{6}$/ ) {
      Log3( $hash, 3, "$hash->{NAME} RGB requires parameter: Hex RRGGBB (e.g. 3478DE)" );
      return "$hash->{NAME} RGB requires parameter: Hex RRGGBB (e.g. 3478DE)";
    }

    # break down param string into discreet RGB values, also Hex to Int
    my $red   = hex( substr( $args[0], 0, 2 ) );
    my $green = hex( substr( $args[0], 2, 2 ) );
    my $blue  = hex( substr( $args[0], 4, 2 ) );
    Log3( $hash, 5, "$hash->{NAME} raw: $args[0], r: $red, g: $green, b: $blue" );
    my ( $hue, $sat, $val ) = LedController_RGB2HSV( $hash, $red, $green, $blue );
    LedController_SetHSVColor( $hash, $hue, $sat, $val, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'on' ) {

    # Add check to only do something if the controller is REALLY turned off, i.e. val eq 0
    my $state = ReadingsVal( $hash->{NAME}, "stateLight", "off" );
    return undef if ( $state eq "on" );

    # OK, state was off
    # val initialized from internal value.
    # if internal was 0, default to 100;
    my $val = $hash->{helper}->{oldVal};
    if ( $val eq 0 ) {
      $val = 100;
    }
    my $hue = InternalVal( $hash->{NAME}, "hueValue", 0 );
    my $sat = InternalVal( $hash->{NAME}, "satValue", 0 );

    # Load default color from attributes (DEPRECATED)
    my $defaultColor = AttrVal( $hash->{NAME}, 'defaultColor', undef );
    if ( defined $defaultColor ) {
      Log3( $hash, 2, "$hash->{NAME} attr \"defaultColor\" is deprecated. Please use the new Attrs defaultHue, defaultSat and defaultVal individually." );

      # Split defaultColor and if all three components pass rangeCheck set them.
      my ( $dcHue, $dcSat, $dcVal ) = split( ',', $defaultColor );
      if ( LedController_rangeCheck( $dcHue, 0, 360 ) && LedController_rangeCheck( $dcSat, 0, 100 ) && LedController_rangeCheck( $dcVal, 0, 100 ) ) {

        # defaultColor values are valid. Overwrite current hue/sat/val.
        $hue = $dcHue;
        $sat = $dcSat;
        $val = $dcVal;
      }
    }

    # defaultHue/Sat/Val will overwrite old values if present because this is "on" cmd.
    my $dHue = AttrVal( $hash->{NAME}, "defaultHue", $hue );
    my $dSat = AttrVal( $hash->{NAME}, "defaultSat", $sat );
    my $dVal = AttrVal( $hash->{NAME}, "defaultVal", $val );

    # range/sanity check
    $hue = LedController_rangeCheck( $dHue, 0, 360 ) ? $dHue : $hue;
    $sat = LedController_rangeCheck( $dSat, 0, 100 ) ? $dSat : $sat;
    $val = LedController_rangeCheck( $dVal, 0, 100 ) ? $dVal : $val;

    Log3( $hash, 5, "$hash->{NAME} setting VAL to $val, SAT to $sat and HUE $hue" );
    Log3( $hash, 5, "$hash->{NAME} args[0] = $args[0], args[1] = $args[1]" );

    LedController_SetHSVColor( $hash, $hue, $sat, $val, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'off' ) {

    # Store old val in internal for use by on command.
    $hash->{helper}->{oldVal} = ReadingsVal( $hash->{NAME}, "val", 0 );

    # Now set val to zero, read other values and "turn out the light"...
    LedController_SetHSVColor( $hash, "+0", "+0", 0, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'toggle' ) {
    my $state = ReadingsVal( $hash->{NAME}, "stateLight", "off" );
    if ( $state eq "on" ) {
      return LedController_Set( $hash, $name, "off", @args );
    }
    else {
      return LedController_Set( $hash, $name, "on", @args );
    }
  }
  elsif ( $cmd eq "dimup" ) {

    # dimming value is first parameter, add to $val and keep hue and sat the way they were.
    my $dim = $args[0];
    LedController_SetHSVColor( $hash, undef, undef, "+" . $dim, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue,
      $fadeName );
  }
  elsif ( $cmd eq "dimdown" ) {

    # dimming value is first parameter, add to $val and keep hue and sat the way they were.
    my $dim = $args[0];
    LedController_SetHSVColor( $hash, undef, undef, "-" . $dim, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue,
      $fadeName );
  }
  elsif ( $cmd eq 'val' || $cmd eq 'dim' ) {

    # Set val from arguments, keep hue and sat the way they were
    my $val = $args[0];

    # input validation
    if ( !LedController_rangeCheck( $val, 0, 100 ) ) {
      Log3( $hash, 3, "$hash->{NAME} value must be a number from 0-100" );
      return "$hash->{NAME} value must be a number from 0-100";
    }

    Log3( $hash, 5, "$hash->{NAME} setting VAL to $val" );
    LedController_SetHSVColor( $hash, undef, undef, $val, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'sat' ) {

    # get new saturation value $sat from args, keep hue and val the way they were.
    my $sat = $args[0];

    # input validation
    if ( !LedController_rangeCheck( $sat, 0, 100 ) ) {
      Log3( $hash, 3, "$hash->{NAME} sat value must be a number from 0-100" );
      return "$hash->{NAME} sat value must be a number from 0-100";
    }

    Log3( $hash, 5, "$hash->{NAME} setting SAT to $sat" );
    LedController_SetHSVColor( $hash, undef, $sat, undef, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'hue' ) {

    # get new hue value $sat from args, keep sat and val the way they were.
    my $hue = $args[0];

    # input validation
    if ( !LedController_rangeCheck( $hue, 0, 360 ) ) {
      Log3( $hash, 3, "$hash->{NAME} hue value must be a number from 0-360" );
      return "$hash->{NAME} hue value must be a number from 0-360";
    }

    Log3( $hash, 5, "$hash->{NAME} setting HUE to $hue" );
    Log3( $hash, 5, "$hash->{NAME} got extended args: t = $fadeTime, q = $doQueue, d=$direction" );

    LedController_SetHSVColor( $hash, $hue, undef, undef, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'raw' ) {
    my ( $red, $green, $blue, $ww, $cw ) = split ',', $args[0];

    $red   = undef if ( length($red) == 0 );
    $green = undef if ( length($green) == 0 );
    $blue  = undef if ( length($blue) == 0 );
    $ww    = undef if ( length($ww) == 0 );
    $cw    = undef if ( length($cw) == 0 );

    LedController_SetRAWColor( $hash, $red, $green, $blue, $ww, $cw, $colorTemp, $fadeTime, $transitionType, $doQueue, $direction, $doRequeue, $fadeName );
  }
  elsif ( $cmd eq 'continue' || $cmd eq 'pause' || $cmd eq 'skip' || $cmd eq 'stop' ) {
    LedController_SetChannelCommand( $hash, $cmd, $channels );
    $forwardToSlaves = 1;
  }
  elsif ( $cmd eq 'blink' ) {
    my $param = LedController_GetHttpParams( $hash, "POST", "blink", "" );
    $param->{parser} = \&LedController_ParseBoolResult;

    my $body = {};

    if ( defined $channels ) {
      my @c = split /,/, $channels;
      $body->{channels} = \@c;
    }
    $body->{t} = $fadeTime  if defined $fadeTime;
    $body->{q} = $doQueue   if defined($doQueue);
    $body->{r} = $doRequeue if defined($doRequeue);

    eval { $param->{data} = LedController_EncodeJson( $hash, $body ) };
    if ($@) {
      Log3( $hash, 2, "$hash->{NAME}: error encoding blink request $@" );
      return undef;
    }
    Log3( $hash, 3, "$hash->{NAME} BLINK o $param->{data}" );
    LedController_addCall( $hash, $param );
    $forwardToSlaves = 1;
  }
  elsif ( $cmd eq 'config' ) {
    return "Invalid syntax: Use 'set <device> <parameter> <value>'" if ( @args != 2 );

    my $param = LedController_GetHttpParams( $hash, "POST", "config", "" );
    $param->{parser} = \&LedController_ParseBoolResult;

    my @keys = split /-/, $args[0];
    return "Invalid config parameter name!" if ( @keys < 2 );

    my $body    = {};
    my $curNode = $body;

    for my $i ( 1 .. ($#keys) ) {
      if ( $i == ($#keys) ) {
        $curNode->{ $keys[$i] } = $args[1];
      }
      else {
        my $newNode = {};
        $curNode->{ $keys[$i] } = $newNode;
        $curNode = $newNode;
      }
    }

    eval { $param->{data} = LedController_EncodeJson( $hash, $body ) };
    if ($@) {
      Log3( $hash, 2, "$hash->{NAME}: error encoding config request $@" );
      return undef;
    }
    Log3( $hash, 3, "post config: " . $param->{data} );
    LedController_addCall( $hash, $param );
    Log3( $hash, 3, "Get config" );
    LedController_GetConfig($hash);
  }
  elsif ( $cmd eq 'restart' ) {
    LedController_SendSystemCommand( $hash, $cmd );
  }
  elsif ( $cmd eq 'fw_update' ) {
    return "Invalid syntax: Use 'set <device> fw_update [<URL to version.json>] [<force>]'" if ( @args > 2 );

    my $force = 0;
    my $url = ReadingsVal( $hash->{NAME}, "config-ota-url", "" );
    if ( defined( $args[0] ) ) {
      if ( LedController_isNumeric( $args[0] ) ) {
        $force = $args[0];
      }
      else {
        $url = $args[0];
        $force = defined( $args[1] ) ? $args[1] : 0;
      }
    }

    LedController_FwUpdate_GetVersion( $hash, $url, $force );
  }
  else {
    my $cmdList = "hsv rgb:colorpicker,RGB state hue sat stop val dim dimup dimdown on off toggle raw pause continue blink skip config restart fw_update";
    return SetExtensions( $hash, $cmdList, $name, $cmd, @args );
  }

  if ($forwardToSlaves) {
    LedController_ForwardToSlaves( $hash, $cmd, \@args );
  }

  return undef;
}

sub LedController_SendSystemCommand(@) {
  my ( $hash, $cmd ) = @_;
  my $param = LedController_GetHttpParams( $hash, "POST", "system", "" );
  $param->{parser} = \&LedController_ParseBoolResult;

  my $body = { cmd => $cmd };
  eval { $param->{data} = LedController_EncodeJson( $hash, $body ) };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding system command request $@" );
    return undef;
  }
  LedController_addCall( $hash, $param );
}

sub LedController_ForwardToSlaves(@) {
  my ( $hash, $cmd, $args ) = @_;

  my $slaveAttr = AttrVal( $hash->{NAME}, "slaves", "" );
  return if ( $slaveAttr eq "" );

  my @slaves = split / /, $slaveAttr;
  for my $slaveDev (@slaves) {
    my ( $slaveName, $offsets ) = split /:/, $slaveDev;

    my $slaveCmd = "set $slaveName $cmd " . join( ",", @{$args} );
    Log3( $hash, 3, "$hash->{NAME} LedController_ForwardToSlaves: $slaveCmd" );
    fhem($slaveCmd);
  }
}

sub LedController_GetConfig(@) {
  my ($hash) = @_;
  my $param = LedController_GetHttpParams( $hash, "GET", "config", "" );
  $param->{parser} = \&LedController_ParseConfig;

  LedController_addCall( $hash, $param );
}

sub LedController_SetChannelCommand(@) {
  my ( $hash, $cmd, $channels ) = @_;
  my $param = LedController_GetHttpParams( $hash, "POST", $cmd, "" );
  $param->{parser} = \&LedController_ParseBoolResult;

  my $body = {};
  if ( defined $channels ) {
    my @c = split /,/, $channels;
    $body->{channels} = \@c;
  }

  eval { $param->{data} = LedController_EncodeJson( $hash, $body ) };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding channel command request $@" );
    return undef;
  }
  LedController_addCall( $hash, $param );
}

sub LedController_Attr(@) {

  my ( $cmd, $device, $attribName, $attribVal ) = @_;
  my $hash = $defs{$device};

  if ( $cmd eq 'set' ) {
    if ( $attribName eq 'colorTemp' ) {
      return "colorTemp must be between 2000 and 10000" if !LedController_rangeCheck( $attribVal, 2000, 10000 );
    }
    elsif ( $attribName eq 'slaves' ) {
      my @slaves = split / /, $attribVal;
      for my $slaveDev (@slaves) {
        my ( $slaveName, $offsets ) = split /:/, $slaveDev;
        if ( $slaveName eq $hash->{NAME} ) {
          return "You cannot set the current devices as a slave (infinite loop)!";
        }
        next if not defined $offsets;
        my @offSplit = split /,/, $offsets;
        if ( @offSplit != 3 ) {
          return 'Invalid Syntax for attribute slaves. Use: slave:off_h,off_s,off_v';
        }
      }
    }
  }

  # TODO: Add checks for defaultColor, defaultHue/Sat/Val here!
  Log3( $hash, 4, "$hash->{NAME} attrib $attribName $cmd $attribVal" );
  return undef;
}

# restore previous settings (as set statefile)
sub LedController_Notify(@) {

  my ( $hash, $eventSrc ) = @_;
  my $events = deviceEvents( $eventSrc, 1 );
  my ( $hue, $sat, $val );
}

sub LedController_GetInfo(@) {
  my ($hash) = @_;
  my $param = LedController_GetHttpParams( $hash, "GET", "info", "" );
  $param->{parser} = \&LedController_ParseInfo;

  LedController_addCall( $hash, $param );
  return undef;
}

sub LedController_IterateConfigHash($$$);

sub LedController_IterateConfigHash($$$) {
  my ( $hash, $readingPrefix, $ref ) = @_;
  foreach my $key ( keys %{$ref} ) {
    my $newPrefix = $readingPrefix . "-" . $key;
    if ( ref( $ref->{$key} ) eq "HASH" ) {
      LedController_IterateConfigHash( $hash, $newPrefix, $ref->{$key} );
    }
    else {
      readingsBulkUpdate( $hash, $newPrefix, $ref->{$key} );
    }
  }
}

sub LedController_ParseConfig(@) {
  my ( $hash, $err, $data ) = @_;

  my $res;

  Log3( $hash, 3, "$hash->{NAME}: got config response" );

  if ($err) {
    Log3( $hash, 2, "$hash->{NAME}: error $err retrieving config" );
  }
  elsif ($data) {
    Log3( $hash, 3, "$hash->{NAME}: config response data $data" );
    eval {

      # TODO: Can't we just store the instance of the JSON parser somewhere?
      # Would that improve performance???
      eval { $res = JSON->new->utf8(1)->decode($data); };
    };
    if ($@) {
      Log3( $hash, 2, "$hash->{NAME}: error decoding config response $@" );
    }
    else {
      Log3( $hash, 3, "$hash->{NAME}: executing readings" );
      fhem( "deletereading " . $hash->{NAME} . " config-.*", 1 );
      readingsBeginUpdate($hash);
      LedController_IterateConfigHash( $hash, "config", $res );
      readingsEndUpdate( $hash, 1 );
    }
  }
  else {
    Log3( $hash, 2, "$hash->{NAME}: error <empty data received> retriving config" );
  }
  return undef;
}

sub LedController_ParseInfo(@) {
  my ( $hash, $err, $data ) = @_;

  my $res;

  Log3( $hash, 3, "$hash->{NAME}: got info response" );

  if ($err) {
    Log3( $hash, 2, "$hash->{NAME}: error $err retrieving info" );
  }
  elsif ($data) {
    Log3( $hash, 3, "$hash->{NAME}: info response data $data" );
    eval {

      # TODO: Can't we just store the instance of the JSON parser somewhere?
      # Would that improve performance???
      eval { $res = JSON->new->utf8(1)->decode($data); };
    };
    if ($@) {
      Log3( $hash, 2, "$hash->{NAME}: error decoding info response $@" );
    }
    else {
      fhem( "deletereading " . $hash->{NAME} . " info-.*", 1 );
      readingsBeginUpdate($hash);
      readingsBulkUpdate( $hash, 'info-deviceid', $res->{deviceid} );
      readingsBulkUpdate( $hash, 'info-firmware', $res->{firmware} );
      readingsBulkUpdate( $hash, 'info-mac',      $res->{connection}->{mac} );
      readingsEndUpdate( $hash, 1 );
    }
  }
  else {
    Log3( $hash, 2, "$hash->{NAME}: error <empty data received> retrieving info" );
  }
  return undef;
}

sub LedController_FwUpdate_GetVersion(@) {
  my ( $hash, $url, $force ) = @_;

  $hash->{helper}->{fwUpdateForce} = $force;

  my $params = {
    url      => $url,
    timeout  => 30,
    hash     => $hash,
    method   => "GET",
    header   => "User-Agent: fhem\r\nAccept: application/json",
    callback => \&LedController_ParseFwVersionResult,
    forceFw  => $force
  };

  HttpUtils_NonblockingGet($params);
}

sub LedController_QueueFwUpdateProgressCheck(@) {
  my ($hash) = @_;

  InternalTimer( time() + 1, "LedController_FwUpdateProgressCheck", $hash, 0 );
}

sub LedController_FwUpdateProgressCheck(@) {
  my ($hash) = @_;
  my $param = LedController_GetHttpParams( $hash, "GET", "update", "" );
  $param->{parser} = \&LedController_ParseFwUpdateProgress;

  LedController_addCall( $hash, $param );
}

sub LedController_ParseFwVersionResult(@) {
  my ( $param, $err, $data ) = @_;
  my $hash  = $param->{hash};
  my $force = $param->{forceFw};

  my $res;

  Log3( $hash, 4, "$hash->{NAME}: LedController_FwVersionCallback" );
  if ($err) {
    readingsSingleUpdate( $hash, "lastFwUpdate", "Error: $err", 1 );
    Log3( $hash, 2, "$hash->{NAME}: LedController_FwVersionCallback error: $err" );
  }
  elsif ($data) {
    eval { $res = JSON->new->utf8(1)->decode($data); };
    if ($@) {
      readingsSingleUpdate( $hash, "lastFwUpdate", "error decoding FW version", 1 );
      Log3( $hash, 2, "$hash->{NAME}: LedController_ParseFwVersionResult error decoding FW version: $@" );
      return undef;
    }

    my $curFw = ReadingsVal( $hash->{NAME}, "info-firmware", "" );
    my $newFw = $res->{rom}{fw_version};
    if ( $newFw eq $curFw ) {
      if ($force) {
        Log3( $hash, 3, "$hash->{NAME}: Firmware already installed: $newFw. Still updating due to force flag!" );
      }
      else {
        my $msg = "Update skipped. Firmware already installed: $newFw";
        readingsSingleUpdate( $hash, "lastFwUpdate", $msg, 1 );
        Log3( $hash, 3, "$hash->{NAME}: $msg" );
        return undef;
      }
    }

    my $msg = "Updating firmware now. Current firmware: $curFw New firmare: $newFw";
    readingsSingleUpdate( $hash, "lastFwUpdate", $msg, 1 );
    Log3( $hash, 3, "$hash->{NAME}: $msg" );

    my $param = LedController_GetHttpParams( $hash, "POST", "update", "" );
    $param->{parser} = \&LedController_ParseBoolResult;

    $param->{data} = $data;
    LedController_addCall( $hash, $param );

    LedController_QueueFwUpdateProgressCheck($hash);
  }

  return undef;
}

sub LedController_ParseFwUpdateProgress(@) {
  my ( $hash, $err, $data ) = @_;

  my $res;
  if ($err) {
    Log3( $hash, 2, "$hash->{NAME}: LedController_ParseFwUpdateProgress error: $err" );
    readingsSingleUpdate( $hash, "lastFwUpdate", "ParseFwUpdateProgress error: $err", 1 );
  }
  elsif ($data) {
    eval { $res = JSON->new->utf8(1)->decode($data); };
    if ($@) {
      my $msg = "error decoding FW update status $@";
      readingsSingleUpdate( $hash, "lastFwUpdate", $msg, 1 );
      Log3( $hash, 4, "$hash->{NAME}: $msg" );
      return undef;
    }

    my $status = $res->{status};
    Log3( $hash, 3, "$hash->{NAME}: LedController_ParseFwUpdateProgress. status: $status" );

    if ( $status == 2 ) {
      my $msg = "Update successful - Restarting device...";
      readingsSingleUpdate( $hash, "lastFwUpdate", $msg, 1 );
      Log3( $hash, 3, "$hash->{NAME}: LedController_ParseFwUpdateProgress - $msg" );
      LedController_SendSystemCommand( $hash, "restart" );
    }
    elsif ( $status == 1 ) {

      # OTA_PROCESSING
      LedController_QueueFwUpdateProgressCheck($hash);
      readingsSingleUpdate( $hash, "lastFwUpdate", "Update in progress", 1 );
    }
    elsif ( $status == 4 ) {

      # OTA_FAILED
      Log3( $hash, 3, "$hash->{NAME}: LedController_ParseFwUpdateProgress - Update failed!" );
      readingsSingleUpdate( $hash, "lastFwUpdate", "Update failed!", 1 );
    }
    else {
      Log3( $hash, 3, "$hash->{NAME}: LedController_ParseFwUpdateProgress - Unexpected update status: $status" );
      readingsSingleUpdate( $hash, "lastFwUpdate", "Unexpected update status: $status", 1 );
    }
  }

  return undef;
}

sub LedController_GetHttpParams(@) {
  my ( $hash, $method, $path, $query ) = @_;
  my $ip = $hash->{IP};

  my $param = {
    url      => "http://$ip/$path?$query",
    timeout  => 30,
    hash     => $hash,
    method   => $method,
    header   => "User-Agent: fhem\r\nAccept: application/json",
    callback => \&LedController_callback
  };
  return $param;
}

sub LedController_GetCurrentColor(@) {
  my ($hash) = @_;
  my $ip = $hash->{IP};

  my $param = LedController_GetHttpParams( $hash, "GET", "color", "" );
  $param->{parser} = \&LedController_ParseColor;

  LedController_addCall( $hash, $param );
  return undef;
}

sub LedController_ParseColor(@) {
  my ( $hash, $err, $data ) = @_;
  my $res;

  Log3( $hash, 4, "$hash->{NAME}: got color response" );

  if ($err) {
    Log3( $hash, 2, "$hash->{NAME}: error $err retrieving color" );
  }
  elsif ($data) {
    eval { $res = JSON->new->utf8(1)->decode($data); };
    if ($@) {
      Log3( $hash, 4, "$hash->{NAME}: error decoding color response $@" );
    }
    else {
      LedController_UpdateReadingsHsv( $hash, $res->{hsv}->{h}, $res->{hsv}->{s}, $res->{hsv}->{v}, $res->{hsv}->{ct} );
      LedController_UpdateReadingsRaw( $hash, $res->{raw}->{r}, $res->{raw}->{g}, $res->{raw}->{b}, $res->{raw}->{cw}, $res->{raw}->{ww} );
    }
  }
  else {
    Log3( $hash, 2, "$hash->{NAME}: error <empty data received> retriving HSV color" );
  }
  return undef;
}

sub LedController_fixHueCircular(@) {
  my ($hue) = @_;

  $hue = $hue % 360 if ( $hue > 360 );
  while ( $hue < 0 ) {
    $hue = 360 + $hue;
  }
  return $hue;
}

sub LedController_GetQueuePolicyFlags($) {
  my ($q) = @_;
  return "q" if ( $q eq "back" );
  return "f" if ( $q eq "front" );
  return "e" if ( $q eq "front_reset" );
  return undef;
}

sub LedController_SetHSVColor_Slaves(@) {
  my ( $hash, $hue, $sat, $val, $colorTemp, $fadeTime, $transitionType, $doQueue, $direction, $doRequeue, $name ) = @_;

  my $slaveAttr = AttrVal( $hash->{NAME}, "slaves", "" );
  return if ( $slaveAttr eq "" );

  my $flags = '';
  $flags .= LedController_GetQueuePolicyFlags($doQueue);
  $flags .= "r" if $doRequeue;
  $flags .= ":$name" if defined($name);

  $fadeTime /= 1000.0;

  my @slaves = split / /, $slaveAttr;
  for my $slaveDev (@slaves) {
    Log3( $hash, 3, "$hash->{NAME}: Processing slave: $slaveDev" );
    my ( $slaveName, $offsets ) = split /:/, $slaveDev;

    if ( defined $offsets ) {
      my @offSplit = split /,/, $offsets;
      $hue += $offSplit[0];
      $sat += $offSplit[1];
      $val += $offSplit[2];

      $val = 0   if $val < 0;
      $val = 100 if $val > 100;
      $sat = 0   if $sat < 0;
      $sat = 100 if $sat > 100;
      $hue = LedController_fixHueCircular($hue);
    }

    my $slaveCmd = "set $slaveName hsv $hue,$sat,$val $fadeTime $flags";
    Log3( $hash, 3, "$hash->{NAME}: Issueing slave command: $slaveCmd" );
    fhem($slaveCmd);
  }

  return undef;
}

sub LedController_EncodeJson($$) {
  my ( $hash, $obj ) = @_;
  my $data;
  eval { $data = JSON->new->utf8(1)->encode($obj); };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding HSV color request $@" );
    return undef;
  }
  return $data;
}

sub LedController_SetHSVColor(@) {
  my ( $hash, $hue, $sat, $val, $colorTemp, $fadeTime, $fadeSpeed, $transitionType, $doQueue, $direction, $doRequeue, $name ) = @_;
  Log3( $hash, 3, "$hash->{NAME}: called SetHSVColor $hue, $sat, $val, $colorTemp, $fadeTime, $transitionType, $doQueue, $direction, $doRequeue, $name)" );

  if ( !defined($hue) && !defined($sat) && !defined($val) && !defined($colorTemp) ) {
    Log3( $hash, 3, "$hash->{NAME}: error: All HSVCT components undefined!" );
    return undef;
  }

  if ( defined($fadeTime) && defined($fadeSpeed) ) {
    Log3( $hash, 3, "$hash->{NAME}: error: fadeTime and fadeSpeed cannot be used at the same time!" );
    return undef;
  }

  my $ip = $hash->{IP};

  my $cmd;
  $cmd->{hsv}->{h}  = $hue            if defined($hue);
  $cmd->{hsv}->{s}  = $sat            if defined($sat);
  $cmd->{hsv}->{v}  = $val            if defined($val);
  $cmd->{hsv}->{ct} = $colorTemp      if defined($colorTemp);
  $cmd->{cmd}       = $transitionType if defined($transitionType);
  $cmd->{t}         = $fadeTime       if defined($fadeTime);
  $cmd->{s}         = $fadeSpeed      if defined($fadeSpeed);
  $cmd->{q}         = $doQueue        if defined($doQueue);
  $cmd->{d}         = $direction      if defined($direction);
  $cmd->{r}         = $doRequeue      if defined($doRequeue);
  $cmd->{name}      = $name           if defined($name);

  my $data;
  eval { $data = JSON->new->utf8(1)->encode($cmd); };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding HSV color request $@" );
  }
  else {

    Log3( $hash, 4, "$hash->{NAME}: encoded json data: $data " );

    my $param = {
      url      => "http://$ip/color",
      data     => $data,
      cmd      => $cmd,
      timeout  => 30,
      hash     => $hash,
      method   => "POST",
      header   => "User-Agent: fhem\r\nAccept: application/json",
      parser   => \&LedController_ParseBoolResult,
      callback => \&LedController_callback,
      loglevel => 5
    };

    Log3( $hash, 5, "$hash->{NAME}: set HSV color request \n$param" );
    LedController_addCall( $hash, $param );
  }

  LedController_SetHSVColor_Slaves(@_);

  return undef;
}

sub LedController_UpdateReadingsHsv(@) {
  my ( $hash, $hue, $sat, $val, $colorTemp ) = @_;
  my ( $red, $green, $blue ) = LedController_HSV2RGB( $hue, $sat, $val );
  my $xrgb = sprintf( "%02x%02x%02x", $red, $green, $blue );
  Log3( $hash, 5, "$hash->{NAME}: calculated RGB as $xrgb" );
  Log3( $hash, 5, "$hash->{NAME}: begin Readings Update\n   hue: $hue\n   sat: $sat\n   val:$val\n   ct : $colorTemp\n   HSV: $hue,$sat,$val\n   RGB: $xrgb" );

  readingsBeginUpdate($hash);
  readingsBulkUpdate( $hash, 'hue', $hue )       if defined $hue;
  readingsBulkUpdate( $hash, 'sat', $sat )       if defined $sat;
  readingsBulkUpdate( $hash, 'val', $val )       if defined $val;
  readingsBulkUpdate( $hash, 'ct',  $colorTemp ) if defined $colorTemp;
  readingsBulkUpdate( $hash, 'hsv', "$hue,$sat,$val" );
  readingsBulkUpdate( $hash, 'rgb', $xrgb );
  readingsBulkUpdate( $hash, 'stateLight', ( $val == 0 ) ? 'off' : 'on' );
  readingsBulkUpdate( $hash, 'colorMode', "hsv" );
  readingsEndUpdate( $hash, 1 );
  return undef;
}

sub LedController_UpdateReadingsRaw(@) {
  my ( $hash, $r, $g, $b, $cw, $ww ) = @_;

  readingsBeginUpdate($hash);
  readingsBulkUpdate( $hash, 'raw_red',   $r );
  readingsBulkUpdate( $hash, 'raw_green', $g );
  readingsBulkUpdate( $hash, 'raw_blue',  $b );
  readingsBulkUpdate( $hash, 'raw_cw',    $cw );
  readingsBulkUpdate( $hash, 'raw_ww',    $ww );
  readingsBulkUpdate( $hash, 'colorMode', "raw" );
  readingsEndUpdate( $hash, 1 );
  return undef;
}

sub LedController_SetRAWColor(@) {
  my ( $hash, $red, $green, $blue, $warmWhite, $coldWhite, $colorTemp, $fadeTime, $transitionType, $doQueue, $direction, $doReQueue, $name ) = @_;
  Log3( $hash, 3,
    "$hash->{NAME}: called SetRAWColor $red, $green, $blue, $warmWhite, $coldWhite, $colorTemp, $fadeTime, $transitionType, $doQueue, $direction" );

  my $param = LedController_GetHttpParams( $hash, "POST", "color", "" );
  $param->{parser} = \&LedController_ParseBoolResult;

  my $body = {};
  $body->{raw}->{r}  = $red            if defined($red);
  $body->{raw}->{g}  = $green          if defined($green);
  $body->{raw}->{b}  = $blue           if defined($blue);
  $body->{raw}->{ww} = $warmWhite      if defined($warmWhite);
  $body->{raw}->{cw} = $coldWhite      if defined($coldWhite);
  $body->{raw}->{ct} = $colorTemp      if defined($colorTemp);
  $body->{cmd}       = $transitionType if defined($transitionType);
  $body->{t}         = $fadeTime       if defined($fadeTime);
  $body->{q}         = $doQueue        if defined($doQueue);
  $body->{d}         = $direction      if defined($direction);
  $body->{r}         = $doReQueue      if defined($doReQueue);
  $body->{name}      = $name           if defined($name);

  eval { $param->{data} = LedController_EncodeJson( $hash, $body ) };
  if ($@) {
    Log3( $hash, 2, "$hash->{NAME}: error encoding RAW color request $@" );
    return undef;
  }

  Log3( $hash, 4, "$hash->{NAME}: set RAW color request r:$red g:$green b:$blue ww:$warmWhite cw:$coldWhite" );
  Log3( $hash, 3, "$hash->{NAME}: set RAW color request \n$param->{data}" );
  LedController_addCall( $hash, $param );
}

sub LedController_ParseBoolResult(@) {
  my ( $hash, $err, $data ) = @_;
  my $res;

  Log3( $hash, 4, "$hash->{NAME}: LedController_ParseBoolResult" );
  if ($err) {
    Log3( $hash, 2, "$hash->{NAME}: LedController_ParseBoolResult error: $err" );
  }
  elsif ($data) {
    eval { $res = JSON->new->utf8(1)->decode($data); };
    if ( exists $res->{error} ) {
      Log3( $hash, 3, "$hash->{NAME}: error LedController_ParseBoolResult: $data" );
    }
    elsif ( exists $res->{success} ) {
      Log3( $hash, 4, "$hash->{NAME}: LedController_ParseBoolResult success" );
    }
    else {
      Log3( $hash, 3, "$hash->{NAME}: LedController_ParseBoolResult malformed answer" );
    }
  }

  return undef;
}

###############################################################################
#
# queue and send a api call
#
###############################################################################

sub LedController_addCall(@) {
  my ( $hash, $param ) = @_;

  #  Log3( $hash, 5, "$hash->{NAME}: add to queue: \n\n" . Dumper $param);

  # add to queue
  push @{ $hash->{helper}->{cmdQueue} }, $param;

  # return if busy
  return if $hash->{helper}->{isBusy};

  # do the call
  LedController_doCall($hash);

  return undef;
}

sub LedController_doCall(@) {
  my ($hash) = @_;

  return unless scalar @{ $hash->{helper}->{cmdQueue} };

  # set busy and do it
  $hash->{helper}->{isBusy} = 1;
  my $param = shift @{ $hash->{helper}->{cmdQueue} };

  #Log3( $hash, 3, "$hash->{NAME} send API Call " . Dumper($param->{cmd}) );
  HttpUtils_NonblockingGet($param);

  return undef;
}

sub LedController_callback(@) {
  my ( $param, $err, $data ) = @_;
  my ($hash) = $param->{hash};

  # TODO generic error handling

  $hash->{helper}->{isBusy} = 0;

  # do the result-parser callback
  my $parser = $param->{parser};
  &$parser( $hash, $err, $data );

  # more calls ?
  LedController_doCall($hash) if scalar @{ $hash->{helper}->{cmdQueue} };

  return undef;
}

###############################################################################
#
# helper functions
#
###############################################################################

sub LedController_RGB2HSV(@) {
  my ( $hash, $red, $green, $blue ) = @_;
  $red   = ( $red * 1023 ) / 255;
  $green = ( $green * 1023 ) / 255;
  $blue  = ( $blue * 1023 ) / 255;

  my ( $max, $min, $delta );
  my ( $hue, $sat, $val );

  $max = $red   if ( ( $red >= $green ) && ( $red >= $blue ) );
  $max = $green if ( ( $green >= $red ) && ( $green >= $blue ) );
  $max = $blue  if ( ( $blue >= $red )  && ( $blue >= $green ) );
  $min = $red   if ( ( $red <= $green ) && ( $red <= $blue ) );
  $min = $green if ( ( $green <= $red ) && ( $green <= $blue ) );
  $min = $blue  if ( ( $blue <= $red )  && ( $blue <= $green ) );

  $val = int( ( $max / 10.23 ) + 0.5 );
  $delta = $max - $min;

  my $currentHue = InternalVal( $hash->{NAME}, "hueValue", 0 ) + 0;
  return ( $currentHue, 0, $val ) if ( ( $max == 0 ) || ( $delta == 0 ) );

  $sat = int( ( ( $delta / $max ) * 100 ) + 0.5 );
  $hue = ( $green - $blue ) / $delta if ( $red == $max );
  $hue = 2 + ( $blue - $red ) / $delta  if ( $green == $max );
  $hue = 4 + ( $red - $green ) / $delta if ( $blue == $max );
  $hue = int( ( $hue * 60 ) + 0.5 );
  $hue += 360 if ( $hue < 0 );
  return $hue, $sat, $val;
}

sub LedController_HSV2RGB(@) {
  my ( $hue, $sat, $val ) = @_;

  if ( $sat == 0 ) {
    return int( ( $val * 2.55 ) + 0.5 ), int( ( $val * 2.55 ) + 0.5 ), int( ( $val * 2.55 ) + 0.5 );
  }
  $hue %= 360;
  $hue /= 60;
  $sat /= 100;
  $val /= 100;

  my $i = int($hue);

  my $f = $hue - $i;
  my $p = $val * ( 1 - $sat );
  my $q = $val * ( 1 - $sat * $f );
  my $t = $val * ( 1 - $sat * ( 1 - $f ) );

  my ( $red, $green, $blue );

  if ( $i == 0 ) {
    ( $red, $green, $blue ) = ( $val, $t, $p );
  }
  elsif ( $i == 1 ) {
    ( $red, $green, $blue ) = ( $q, $val, $p );
  }
  elsif ( $i == 2 ) {
    ( $red, $green, $blue ) = ( $p, $val, $t );
  }
  elsif ( $i == 3 ) {
    ( $red, $green, $blue ) = ( $p, $q, $val );
  }
  elsif ( $i == 4 ) {
    ( $red, $green, $blue ) = ( $t, $p, $val );
  }
  else {
    ( $red, $green, $blue ) = ( $val, $p, $q );
  }
  return ( int( ( $red * 255 ) + 0.5 ), int( ( $green * 255 ) + 0.5 ), int( ( $blue * 255 ) + 0.5 ) );
}

sub LedController_ArgsHelper(@) {
  my ( $hash, $offset, @args ) = @_;

  my ( $channels, $requeue, $flags, $time, $speed, $name );
  my $queue          = 'single';
  my $d              = '1';
  my $transitionType = 'fade';
  for my $i ( $offset .. $#args ) {
    my $arg = $args[$i];
    if ( $arg =~ /\((.*)\)/ ) {

      $channels = $1;
    }
    elsif ( LedController_isNumeric($arg) ) {
      $time = $arg * 1000;
    }
    elsif ( substr( $arg, 0, 1 ) == "s" && LedController_isNumeric( substr( $arg, 1 ) ) ) {
      $speed = $arg;
    }
    else {
      ( $flags, $name ) = split /:/, $arg;
      my $queueBack       = ( $flags =~ m/q/i );
      my $queueFront      = ( $flags =~ m/f/i );
      my $queueFrontReset = ( $flags =~ m/e/i );

      if ($queueBack) {
        $queue = 'back';
      }
      elsif ($queueFront) {
        $queue = 'front';
      }
      elsif ($queueFrontReset) {
        $queue = 'front_reset';
      }

      $requeue = 'true' if ( $flags =~ m/r/i );
      $d = ( $flags =~ m/l/ ) ? 0 : 1;

      $transitionType = 'solid' if ( $flags =~ m/s/i );
    }
  }
  Log3( $hash, 5, "LedController_ArgsHelper: Time: $time | Q: $queue | RQ: $requeue | Name: $name | trans: $transitionType | Ch: $channels" );
  return ( undef, $time, $speed, $queue, $d, $requeue, $name, $transitionType, $channels );
}

sub LedController_isNumeric {
  defined $_[0] && $_[0] =~ /^[+-]?\d+.?\d*/;
}

sub LedController_rangeCheck(@) {
  my ( $val, $min, $max ) = @_;
  return LedController_isNumeric($val) && $val >= $min && $val <= $max;
}

1;

=begin html

<a name="LedController"></a>
<h3>LedController</h3>
 <ul>
  <p>The module controls the led controller made by patrick jahns.</p> 
    <p>Additional information you will find in the <a href="https://forum.fhem.de/index.php/topic,48918.0.html">forum</a>.</p> 
  <br><br> 
 
  <a name="LedControllerdefine"></a> 
  <b>Define</b> 
  <ul> 
    <code>define &lt;name&gt; LedController [&lt;type&gt;] &lt;ip-or-hostname&gt;</code> 
    <br><br> 
 
      Example: 
      <ul> 
      <code>define LED_Stripe LedController 192.168.1.11</code><br> 
    </ul> 
  </ul> 
  <br> 
   
  <a name="LedControllerset"></a> 
  <b>Set</b> 
  <ul> 
    <li> 
      <p><code>set &lt;name&gt; <b>on</b> [ramp] [q]</code></p> 
      <p>Turns on the device. It is either chosen 100% White or the color defined by the attribute "defaultColor".</p> 
      <p>Advanced options: 
      <ul> 
        <li>ramp</li> 
      </ul> 
      </p> 
      <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
    </li> 
    <li> 
      <p><code>set &lt;name&gt; <b>off</b> [ramp] [q]</code></p> 
      <p>Turns off the device.</p> 
      <p>Advanced options: 
      <ul> 
        <li>ramp</li> 
      </ul> 
      </p> 
      <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
    </li> 
    <li> 
      <p><code>set &lt;name&gt; <b>dim</b> &lt;level&gt; [ramp] [q]</code></p> 
      <p>Sets the brightness to the specified level (0..100).<br /> 
      This command also maintains the preset color even with "dim 0" (off) and then "dim xx" (turned on) at.  
      Therefore, it represents an alternative form to "off" / "on". The latter would always choose the "default color".</p> 
      <p>Advanced options: 
      <ul> 
        <li>ramp</li> 
      </ul> 
        </p> 
        <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
  <li> 
      <p><code>set &lt;name&gt; <b>dimup / dimdown</b> &lt;level&gt; [ramp] [q]</code></p> 
      <p>Increases / decreases the brightness by the given value.<br /> 
      This command also maintains the preset color even with turning it all the way to 0 (off) and back up.  
      <p>Advanced options: 
      <ul> 
        <li>ramp</li> 
      </ul> 
        </p> 
        <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
    <li> 
    <li> 
      <p><code>set &lt;name&gt; <b>hsv</b> &lt;H,S,V&gt; [ramp] [l|q]</code></p> 
          <p>Sets color, saturation and brightness in the HSV color space. If the ramp is specified (as a time in seconds), the module calculates a soft color transition from the current color to the newly set. 
          <ul><i>For example, sets a saturated blue with half brightness:</i><br /><code>set LED_Stripe hsv 240,100,50</code></ul></p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
       
      <li> 
      <p><code>set &lt;name&gt; <b>hue</b> &lt;value&gt; [ramp] [l|q]</code></p> 
          <p>Sets the color angle (0..360) in the HSV color space. If the ramp is specified (as a time in seconds), the module calculates a soft color transition from the current color to the newly set. 
          <ul><i>For example, changing only the hue with a transition of 5 seconds:</i><br /><code>set LED_Stripe hue 180 5</code></ul></p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
      <p><code>set &lt;name&gt; <b>sat</b> &lt;value&gt; [ramp] [q]</code></p> 
          <p>Sets the saturation in the HSV color space to the specified value (0..100). If the ramp is specified (as a time in seconds), the module calculates a soft color transition from the current saturation to the newly set. 
          <ul><i>For example, changing only the saturation with a transition of 5 seconds:</i><br /><code>set LED_Stripe sat 60 5</code></ul></p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
      <p><code>set &lt;name&gt; <b>val</b> &lt;value&gt; [ramp] [q]</code></p> 
          <p>Sets the brightness to the specified value (0..100). It's the same as cmd <b>dim</b>.</p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
      <p><code>set &lt;name&gt; <b>rotate</b> &lt;angle&gt; [ramp] [l|q]</code></p> 
          <p>Sets the color in the HSV color space by addition of the specified angle to the current color. 
          <ul><i>For example, changing color from current green to blue:</i><br /><code>set LED_Stripe rotate 120</code></ul></p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
          <p><code>set &lt;name&gt; <b>rgb</b> &lt;RRGGBB&gt; [ramp] [l|q]</code></p> 
          <p>Sets the color in the RGB color space.<br> 
          Currently RGB values will be converted into HSV to make use of the internal color compensation of the LedController.</p> 
          <p>Advanced options: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
          <p><code>set &lt;name&gt; <b>update</b></code></p> 
          <p>Gets the current HSV color from the LedController.</p> 
      </li> 
       
      <p><b>Meaning of Flags</b></p> 
      Certain commands (set) can be marked with special flags. 
      <p> 
      <ul> 
        <li>ramp:  
            <ul> 
              Time in seconds for a soft color or brightness transition. The soft transition starts at the currently visible color and is calculated for the specified. 
            </ul> 
        </li> 
        <li>l:  
            <ul> 
              (long). A smooth transition to another color is carried out in the HSV color space on the "long" way. 
              A transition from red to green then leads across magenta, blue, and cyan. 
            </ul> 
        </li> 
        <li>q:  
            <ul> 
              (queue). Commands with this flag are cached in an internal queue of the LedController and will not run before the currently running soft transitions have been processed.  
              Commands without the flag will be processed immediately. In this case all running transitions are stopped immediately and the queue will be cleared. 
            </ul> 
        </li> 
       
  </ul> 
  <br> 
 
  <a name="LedControllerattr"></a> 
  <b>Attributes</b> 
  <ul> 
    <li><a name="defaultColor">defaultColor</a><br> 
    <code>attr &ltname&gt <b>defaultColor</b> &ltH,S,V&gt</code><br> 
    Specify the light color in HSV which is selected at "on". Default is white.</li> 
 
    <li><a name="defaultRamp">defaultRamp</a><br> 
    Time in milliseconds. If this attribute is set, a smooth transition is always implicitly generated if no ramp in the set is indicated.</li> 
 
    <li><a name="colorTemp">colorTemp</a><br> 
    </li>

    <li><a name="slaves">slaves</a><br> 
    List of slave device names seperated by whitespacs. All set-commands will be forwarded to the slave devices. Example: "wz_lampe1 sz_lampe2"
    An offset for the HSV values can be applied for each slave device. Syntax: &lt;slave&gt;:&lt;offset_h&gt;,&lt;offset_s&gt;,&lt;offset_v&gt;
    </li> 
  </ul> 
  <p><b>Colorpicker for FhemWeb</b> 
    <ul> 
      <p> 
      In order for the Color Picker can be used in <a href="#FHEMWEB">FhemWeb</a> following attributes need to be set: 
      <p> 
      <li> 
         <code>attr &ltname&gt <b>webCmd</b> rgb</code> 
      </li> 
      <li> 
         <code>attr &ltname&gt <b>widgetOverride</b> rgb:colorpicker,rgb</code> 
      </li> 
    </ul> 
  <br> 
 
</ul> 
 
=end html 

=begin html_DE

<a name="LedController"></a> 
<h3>LedController</h3> 
<ul> 
<p>Dieses Modul steuert den selbst einwickelten LedController von Patrick Jahns.</p> 
    <p>Weitere Informationen hierzu sind im <a href="https://forum.fhem.de/index.php/topic,48918.0.html">Forum</a> zu finden.</p> 
  <br><br> 
 
  <a name="LedControllerdefine"></a> 
  <b>Define</b> 
  <ul> 
    <code>define &lt;name&gt; LedController [&lt;type&gt;] &lt;ip-or-hostname&gt;</code> 
    <br><br> 
 
      Beispiel: 
      <ul> 
      <code>define LED_Stripe LedController 192.168.1.11</code><br> 
    </ul> 
  </ul> 
  <br> 
   
  <a name="LedControllerset"></a> 
  <b>Set</b> 
  <ul> 
    <li> 
      <p><code>set &lt;name&gt; <b>on</b> [ramp] [q]</code></p> 
      <p>Schaltet das device ein. Dabei wird entweder 100% Weiß oder die im Attribut "defaultColor" definierte Farbe gewählt.</p> 
      <p>Erweiterte Parameter: 
      <ul> 
        <li>ramp</li> 
      </ul> 
      </p> 
      <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
    </li> 
    <li> 
      <p><code>set &lt;name&gt; <b>off</b> [ramp] [q]</code></p> 
      <p>Schaltet das device aus.</p> 
      <p>Erweiterte Parameter: 
      <ul> 
        <li>ramp</li> 
      </ul> 
      </p> 
      <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
    </li> 
    <li> 
      <p><code>set &lt;name&gt; <b>dim</b> &lt;level&gt; [ramp] [q]</code></p> 
      <p>Setzt die Helligkeit auf den angegebenen Wert (0..100).<br /> 
      Dieser Befehl behält außerdem die eingestellte Farbe auch bei "dim 0" (ausgeschaltet) und nachfolgendem "dim xx" (eingeschaltet) bei. 
      Daher stellt er eine alternative Form zu "off" / "on" dar. Letzteres würde immer die "defaultColor" wählen.</p> 
      <p>Erweiterte Parameter: 
      <ul> 
        <li>ramp</li> 
      </ul> 
        </p> 
        <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
      <p><code>set &lt;name&gt; <b>dimup / dimdown</b> &lt;value&gt; [ramp] [q]</code></p> 
      <p>Erhöht oder vermindert die Helligkeit um den angegebenen Wert (0..100).<br /> 
      Dieser Befehl behält außerdem die eingestellte Farbe bei.
      <p>Erweiterte Parameter: 
      <ul> 
        <li>ramp</li> 
      </ul> 
        </p> 
        <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li>     <li> 
      <p><code>set &lt;name&gt; <b>hsv</b> &lt;H,S,V&gt; [ramp] [l|q]</code></p> 
          <p>Setzt die Farbe, Sättigung und Helligkeit im HSV Farbraum. Wenn die ramp (als Zeit in Sekunden) angegeben ist, berechnet das Modul einen weichen Farbübergang von der aktuellen Farbe zur neu gesetzten. 
          <ul><i>Beispiel, setzt ein gesättigtes Blau mit halber Helligkeit:</i><br /><code>set LED_Stripe hsv 240,100,50</code></ul></p> 
          <p>Erweiterte Parameter: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
       
      <li> 
      <p><code>set &lt;name&gt; <b>hue</b> &lt;value&gt; [ramp] [l|q]</code></p> 
          <p>Setzt den Farbwinkel (0..360) im HSV Farbraum. Wenn die ramp (als Zeit in Sekunden) angegeben ist, berechnet das Modul einen weichen Farbübergang von der aktuellen Farbe zur neu gesetzten. 
          <ul><i>Beispiel, nur Änderung des Farbwertes mit einer Animationsdauer von 5 Sekunden:</i><br /><code>set LED_Stripe hue 180 5</code></ul></p> 
          <p>Erweiterte Parameter: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
      <p><code>set &lt;name&gt; <b>sat</b> &lt;value&gt; [ramp] [q]</code></p> 
          <p>Setzt die Sättigung im HSV Farbraum auf den übergebenen Wert (0..100). Wenn die ramp (als Zeit in Sekunden) angegeben ist, berechnet das Modul einen weichen Farbübergang von der aktuellen Sättigung zur neu gesetzten. 
          <ul><i>Beispiel, nur Änderung der Sättigung mit einer Animationsdauer von 5 Sekunden:</i><br /><code>set LED_Stripe sat 60 5</code></ul></p> 
          <p>Erweiterte Parameter: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
      <p><code>set &lt;name&gt; <b>val</b> &lt;value&gt; [ramp] [q]</code></p> 
          <p>Setzt die Helligkeit auf den übergebenen Wert (0..100). Dieser Befehl ist identisch zum <b>"dim"</b> Kommando.</p> 
          <p>Erweiterte Parameter: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
      <p><code>set &lt;name&gt; <b>rotate</b> &lt;angle&gt; [ramp] [l|q]</code></p> 
          <p>Setzt den Farbwinkel im HSV Farbraum durch Addition des Übergebenen Wertes auf die aktuelle Farbe. 
          <ul><i>Beispiel, Änderung der Farbe von aktuell Grün auf Blau:</i><br /><code>set LED_Stripe rotate 120</code></ul></p> 
          <p>Erweiterte Parameter: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
          <p><code>set &lt;name&gt; <b>rgb</b> &lt;RRGGBB&gt; [ramp] [l|q]</code></p> 
          <p>Setzt die Farbe im RGB Farbraum.<br> 
          Aktuell wandelt das Modul den Wert vor dem Senden in einen HSV-Wert um, um die interne Farbkompensation des Led Controllers nutzen zu können.</p> 
          <p>Erweiterte Parameter: 
          <ul> 
              <li>ramp</li> 
          </ul> 
          </p> 
          <p>Flags: 
          <ul> 
              <li>l q</li> 
          </ul> 
          </p> 
      </li> 
      <li> 
          <p><code>set &lt;name&gt; <b>update</b></code></p> 
          <p>Fragt die aktuellen HSV Farbwerte vom Led Controller ab.</p> 
      </li> 
       
      <p><b>Bedeutung der Flags</b></p> 
      Bestimmte Befehle (set) können mit speziellen Flags versehen werden. 
      <p> 
      <ul> 
        <li>ramp:  
            <ul> 
              Zeit in Sekunden für einen weichen Farb- oder Helligkeitsübergang. Der weiche Übergang startet bei der aktuell sichtbaren Farbe und wird zur angegeben berechnet. 
            </ul> 
        </li> 
        <li>l:  
            <ul> 
              (long). Ein weicher Übergang zu einer anderen Farbe wird im Farbkreis auf dem "langen" Weg durchgeführt.</br> 
              Ein Übergang von ROT nach GRÜN führt dann über MAGENTA, BLAU, und CYAN. 
            </ul> 
        </li> 
        <li>q:  
            <ul> 
              (queue). Kommandos mit diesem Flag werden in der (Controller)internen Warteschlange zwischengespeichert und erst ausgeführt nachdem die aktuell laufenden weichen Übergänge 
              abgearbeitet wurden. Kommandos ohne das Flag werden sofort abgearbeitet. Dabei werden alle laufenden Übergänge sofort abgebrochen und die Warteschlange wird gelöscht. 
            </ul> 
        </li> 
       
  </ul> 
  <br> 
 
  <a name="LedControllerattr"></a> 
  <b>Attribute</b> 
  <ul> 
    <li><a name="defaultColor">defaultColor</a><br> 
    <code>attr &ltname&gt <b>defaultColor</b> &ltH,S,V&gt DEPRECATED</code><br> 
    HSV Angabe der Lichtfarbe die bei "on" gewählt wird. Standard ist Weiß.</li> 
 
    <li><a name="defaultRamp">defaultRamp</a><br> 
    Zeit in Millisekunden. Wenn dieses Attribut gesetzt ist wird implizit immer ein weicher Übergang erzeugt wenn keine ramp im set angegeben ist.</li> 
 
    <li><a name="colorTemp">colorTemp</a><br> 
    </li>

    <li><a name="slaves">slaves</a><br> 
    Durch Leerzeichen getrennte Liste von Slave-Geräten. Alle set-Befehle werden an alle Slaves weitergereicht. Beispiel: "wz_lampe1 sz_lampe2"
    Für jeden Slave können Offsets für die HSV-Werte konfiguriert werden, so daß sie eine andere Farbe als der Master wiedergeben. Syntax: &lt;slave&gt;:&lt;offset_h&gt;,&lt;offset_s&gt;,&lt;offset_v&gt;
    </li> 
    </ul> 
  <p><b>Colorpicker für FhemWeb</b> 
    <ul> 
      <p> 
      Um den Color-Picker für <a href="#FHEMWEB">FhemWeb</a> zu aktivieren müssen folgende Attribute gesetzt werden: 
      <p> 
      <li> 
         <code>attr &ltname&gt <b>webCmd</b> rgb</code> 
      </li> 
      <li> 
         <code>attr &ltname&gt <b>widgetOverride</b> rgb:colorpicker,rgb</code> 
      </li> 
    </ul> 
  <br> 
 
</ul> 
 
=end html_DE 
=cut
