#!/usr/bin/perl -cw

use strict;
use warnings;

package Data::JSEmail;

our $VERSION = '0.02';

use JSON;
use JSON::XS;
use HTML::Strip;
use Email::MIME;
use Email::MIME::ContentType;
use Email::MIME::Header::AddressList;
use Encode;
use Encode::MIME::Header;
use Unicode::Normalize;
use Date::Format;
use Date::Parse;
use DateTime;
use DateTime::Format::Mail;
use DateTime::Format::ISO8601::Format;

use Digest::SHA;

my $json = JSON::XS->new->utf8->canonical();

sub parse {
  my $rfc822 = shift;
  my $id = shift || Digest::SHA::sha256_hex($rfc822);
  my $eml = Email::MIME->new($rfc822);
  my $res = parse_email($id, $eml);
  $res->{size} = length($rfc822);
  return $res;
}

sub parse_email {
  my $id = shift;
  my $eml = shift;
  my $part = shift;

  my $preview = preview($eml);
  my $headers = headers($eml);

  my %values;
  my $bodystructure = bodystructure(\%values, $id, $eml);
  my $textBody = [];
  my $htmlBody = [];
  my $attachments = [];
  parseStructure([$bodystructure], 'mixed', 0, $textBody, $htmlBody, $attachments);

  my ($hasAtt) = grep { ($_->{disposition} // '') ne 'inline' } @$attachments;
  my $data = {
    id => $id,
    sender => asAddresses($eml->header('Sender')),
    to => asAddresses($eml->header('To')),
    cc => asAddresses($eml->header('Cc')),
    bcc => asAddresses($eml->header('Bcc')),
    from => asAddresses($eml->header('From')),
    replyTo => asAddresses($eml->header('Reply-To')),
    subject => asText($eml->header('Subject')),
    sentAt => asDate($eml->header('Date')),
    messageId => asMessageIds($eml->header('Message-Id')),
    references => asMessageIds($eml->header('References')),
    inReplyTo => asMessageIds($eml->header('In-Reply-To')),
    preview => $preview,
    hasAttachment => $hasAtt ? $JSON::true : $JSON::false,
    headers => $headers,
    bodyStructure => $bodystructure,
    bodyValues => \%values,
    textBody => $textBody,
    htmlBody => $htmlBody,
    attachments => $attachments,
  };

  return $data;
}

sub bodystructure {
  my $values = shift;
  my $id = shift;
  my $eml = shift;
  my $partno = shift;

  my $type = {
    'subtype' => 'plain',
    'type' => 'text'
  };
  if (my $val = $eml->header('Content-Type')) {
    $type = parse_content_type($val);
  }
  my @parts = $eml->subparts();
  if (@parts) {
    my @sub;
    for (my $n = 1; $n <= @parts; $n++) {
      push @sub, bodystructure($values, $id, $parts[$n-1], $partno ? "$partno.$n" : $n);
    }
    return {
      partId => undef,
      blobId => undef,
      type => "$type->{type}/$type->{subtype}",
      size => 0,
      headers => headers($eml),
      name => undef,
      cid => asOneURL($eml->header('Content-Id')),
      charset => $type->{attributes}{charset},
      language => asCommaList($eml->header('Content-Language')),
      location => undef,
      disposition => undef,
      subParts => \@sub,
    };
  }
  else {
    my $disposition = {};
    if (my $val = $eml->header('Content-Disposition')) {
      my $orig = $val;
      $val =~ s{^(.*filename=\s*)([^\s"][^;]+)}{$1"$2"};
      $disposition = parse_content_disposition($val);
    }
    $partno ||= '1';
    my $body = $eml->body();
    my $raw_size = length($body); # size in octets of decoded content
    if ($type->{type} eq 'text') {
      # Decode charset to Perl character string
      my $decoded = eval { $eml->body_str() };
      if (defined $decoded) {
        $body = $decoded;
      } else {
        # Fallback: try UTF-8 decode
        $body = eval { Encode::decode('UTF-8', $body) } // $body;
      }
      # RFC 8621: line endings in bodyValues MUST be \n not \r\n
      my $text_body = $body;
      $text_body =~ s/\r\n/\n/g;
      $values->{$partno} = {
        value => $text_body,
        isEncodingProblem => (defined $decoded ? $JSON::false : $JSON::true),
        isTruncated => $JSON::false,
      };
    }
    my $charset = $type->{attributes}{charset};
    if ($type->{type} eq 'text' and not $charset) {
      $charset = 'us-ascii';
    }
    return {
      partId => "$partno",
      blobId => "m-$id-$partno",
      type => "$type->{type}/$type->{subtype}",
      size => $raw_size,
      headers => headers($eml),
      name => $disposition->{attributes}{filename} // $type->{attributes}{name},
      cid => asOneURL($eml->header('Content-Id')),
      charset => $charset,
      language => asCommaList($eml->header('Content-Language')),
      location => asText($eml->header('Content-Location')),
      disposition => $disposition->{type},
    };
  }
}

sub asDate {
  my $val = shift;
  return undef unless defined $val;
  $val =~ s/\(.*//;
  my $dt = eval { DateTime::Format::Mail->parse_datetime($val) };
  return undef unless $dt;
  my $tz = $dt->time_zone;
  if ($tz->isa('DateTime::TimeZone::Floating')) {
    $dt->set_time_zone('UTC');
  }
  return DateTime::Format::ISO8601::Format->new->format_datetime($dt);
}

sub asMessageIds {
  my $val = shift;
  return undef unless $val;
  my @list = $val =~ m{<([^\>]+)>}gs;
  return undef unless @list;
  return \@list;
}

sub asCommaList {
  my $val = shift;
  return undef unless defined $val;
  $val =~ s/^\s+//;
  $val =~ s/\s+$//;
  my @list = split /\s*,\s*/, $val;
  return \@list;
}

# NOTE: this is totally bogus..
sub asURLs {
  my $val = shift;
  return undef unless defined $val;
  unless ($val =~ m/\<.*\>/) {
    $val =~ s/^\s+//;
    $val =~ s/ .*//; # strip everything after first whitespace
    return undef unless length($val);
    return [$val];
  }

  my @list;
  while ($val =~ m/<([^>]+)>/gs) {
    push @list, $1;
  }
  return \@list;
}

sub asOneURL {
  my $val = shift;
  my $list = asURLs($val) || [];
  return $list->[-1];
}

sub asText {
  my $val = shift;
  return undef unless defined $val;
  my $res = encode_utf8(NFC(decode('MIME-Header', $val)));
  $res =~ s/^\s*//;
  $res =~ s/\s*$//;
  return $res;
}

sub asAddresses {
  my $emails = shift;

  my $res = asGroupAddresses($emails);
  return undef unless $res;

  my $arr = [ grep { defined $_->{email} } @$res ];
  return $arr;
}

sub asGroupAddresses {
  my $emails = shift;

  return undef unless defined $emails;
  my $addrs = Email::MIME::Header::AddressList->from_mime_string($emails);
  my @addrs = $addrs->groups();
  my @res;
  while (@addrs) {
    my $group = shift @addrs;
    my $list = shift @addrs;
    if (defined $group) {
      push @res, {
        name => asText($group),
        email => undef,
      };
    }
    foreach my $addr (@$list) {
      my $name = $addr->phrase();
      my $email = $addr->address();
      $email =~ s/\@(.*)/"@" . lc($1)/e;
      push @res, {
        name => asText($name),
        email => $email,
      };
    }
    if (defined $group) {
      push @res, {
        name => undef,
        email => undef,
      };
    }
  }

  return \@res;
}

sub headers {
  my $eml = shift;
  my @list = $eml->header_obj->header_raw_pairs();
  my @res;
  while (@list) {
   my $name = shift @list;
   my $value = shift @list;
    push @res, {
      name => $name,
      value => $value,
    };
  }
  return \@res;
}

sub _clean {
  my ($type, $text) = @_;
  return $text;
}

sub _body_str {
  my $eml = shift;
  my $str = eval { $eml->body_str() };
  return $str if $str;
  return Encode::decode('us-ascii', $eml->body_raw());
}

# XXX: re-define on top of bodyStructure?
sub preview {
  my $eml = shift;
  my $type = $eml->content_type() || 'text/plain';
  if ($type =~ m{text/plain}i) {
    my $text = _clean($type, _body_str($eml));
    return make_preview($text);
  }
  if ($type =~ m{text/html}i) {
    my $text = _clean($type, _body_str($eml));
    return make_preview(htmltotext($text));
  }
  foreach my $sub ($eml->subparts()) {
    my $res = preview($sub);
    return $res if $res;
  }
  return undef;
}

sub make_preview {
  my $text = shift;
  $text =~ s/\s+/ /gs;
  return substr($text, 0, 256);
}

sub hasatt {
  my $bs = shift;
  if ($bs->{subParts}) {
    foreach my $sub (@{$bs->{subParts}}) {
      return 1 if hasatt($sub);
    }
  }
  return 1 if $bs->{type} =~ m{(image|video|application)/};  # others?
  return 0;
}

sub isInlineMediaType {
  my $type = shift;
  return 1 if $type =~ m{^image/};
  return 1 if $type =~ m{^audio/};
  return 1 if $type =~ m{^video/};
  return 0;
}

sub parseStructure {
  my $parts = shift;
  my $multipartType = shift;
  my $inAlternative = shift;
  my $textBody = shift;
  my $htmlBody = shift;
  my $attachments = shift;

  my $textCount = $textBody ? scalar @$textBody : -1;
  my $htmlCount = $htmlBody ? scalar @$htmlBody : -1;

  for (my $i = 0; $i < @$parts; $i++) {
    my $part = $parts->[$i];
    my $isMultipart = $part->{type} =~ m{^multipart/(.*)};
    my $subMultiType = $isMultipart ? $1 : '';

    # Determine part type (matching Cyrus classification)
    my $isPlain = $part->{type} eq 'text/plain'
               || $part->{type} eq 'text/richtext'
               || $part->{type} eq 'text/enriched';
    my $isHTML = $part->{type} eq 'text/html';
    my $isInlineMedia = isInlineMediaType($part->{type});

    my $isInline = ($part->{disposition} // '') ne 'attachment' &&
        ($isPlain || $isHTML || $isInlineMedia) &&
        ($i == 0 ||
            ( $multipartType ne 'related' &&
                ( $isInlineMedia || !$part->{name} ) ) );

    if ($isMultipart) {
      parseStructure($part->{subParts}, $subMultiType,
          $inAlternative || ( $subMultiType eq 'alternative' ),
          $textBody, $htmlBody, $attachments);
    }
    elsif ($isInline) {
      if ($multipartType eq 'alternative') {
        if ($isPlain && $textBody) {
          push @$textBody, $part;
        }
        elsif ($isHTML && $htmlBody) {
          push @$htmlBody, $part;
        }
        else {
          push @$attachments, $part;
        }
        next;
      }
      # Inside an alternative ancestor: seeing a text part means
      # we can't also use it for HTML, and vice versa
      if ($inAlternative) {
        if ($isPlain) {
          $htmlBody = undef;
        }
        elsif ($isHTML) {
          $textBody = undef;
        }
      }
      push @$textBody, $part if $textBody;
      push @$htmlBody, $part if $htmlBody;
      if ((!$textBody || !$htmlBody) && $isInlineMedia) {
        push @$attachments, $part;
      }
    }
    else {
      push @$attachments, $part;
    }
  }

  # Alternative fallback: if only one type was found, copy to the other
  if ($multipartType eq 'alternative' && $textBody && $htmlBody) {
    if ($textCount == scalar @$textBody) {
      # No text parts found, copy HTML parts to text
      push @$textBody, @{$htmlBody}[$htmlCount .. $#$htmlBody];
    }
    if ($htmlCount == scalar @$htmlBody) {
      # No HTML parts found, copy text parts to HTML
      push @$htmlBody, @{$textBody}[$textCount .. $#$textBody];
    }
  }
}

sub _mkone {
  my $h = shift;
  my $email = $h->{email};
  my $name = $h->{name};
  if (defined $name && $name ne '') {
    return qq{"$name" <$email>};
  }
  else {
    return $email;
  }
}

sub _mkemail {
  my $a = shift;
  return join(", ", map { _mkone($_) } @$a);
}

sub _detect_encoding {
  my $content = shift;
  my $type = shift;

  if ($type =~ m/^message/) {
    if ($content =~ m/[^\x{09}\x{0a}\x{0d}\x{20}-\x{7e}]/) {
      return '8bit';
    }
    return '7bit';
  }

  if ($type =~ m/^text/) {
    # XXX - also line lengths?
    if ($content =~ m/[^\x{09}\x{0a}\x{0d}\x{20}-\x{7e}]/) {
      return 'quoted-printable';
    }
    return '7bit';
  }

  return 'base64';
}

sub _makeatt {
  my $att = shift;
  my $getblob = shift;

  my %attributes = (
    content_type => $att->{type},
    name => $att->{name},
    filename => $att->{name},
    disposition => $att->{isInline} ? 'inline' : 'attachment',
  );

  my %headers;
  if ($att->{cid}) {
    $headers{'Content-ID'} = "<$att->{cid}>";
  }

  my ($type, $content) = $getblob->($att->{blobId});

  $attributes{encoding} = _detect_encoding($content, $att->{type});

  return Email::MIME->create(
    attributes => \%attributes,
    headers => \%headers,
    body => $content,
  );
}

sub make {
  my $args = shift;
  my $getblob = shift;

  # RFC 8621 Email/set create format:
  #   from, to, cc, bcc, replyTo, sender: EmailAddress[]
  #   subject: String
  #   sentAt: Date (optional)
  #   messageId, inReplyTo, references: String[]
  #   textBody: EmailBodyPart[] (each with partId referencing bodyValues)
  #   htmlBody: EmailBodyPart[] (each with partId referencing bodyValues)
  #   bodyValues: Id[EmailBodyValue] (partId => {value: String})
  #   attachments: EmailBodyPart[] (each with blobId)

  my @header;
  push @header, From => _mkemail($args->{from}) if $args->{from};
  push @header, To => _mkemail($args->{to}) if $args->{to};
  push @header, Cc => _mkemail($args->{cc}) if $args->{cc};
  push @header, Bcc => _mkemail($args->{bcc}) if $args->{bcc};
  push @header, Subject => $args->{subject} if defined $args->{subject};

  if ($args->{sentAt}) {
    push @header, Date => $args->{sentAt};
  }
  elsif ($args->{msgdate}) {
    push @header, Date => Date::Format::time2str("%a, %d %b %Y %H:%M:%S %z", $args->{msgdate});
  }
  else {
    push @header, Date => Date::Format::time2str("%a, %d %b %Y %H:%M:%S %z", time());
  }

  if ($args->{messageId} && ref($args->{messageId}) eq 'ARRAY' && @{$args->{messageId}}) {
    push @header, 'Message-ID' => join(' ', map { "<$_>" } @{$args->{messageId}});
  }
  if ($args->{inReplyTo} && ref($args->{inReplyTo}) eq 'ARRAY' && @{$args->{inReplyTo}}) {
    push @header, 'In-Reply-To' => join(' ', map { "<$_>" } @{$args->{inReplyTo}});
  }
  if ($args->{references} && ref($args->{references}) eq 'ARRAY' && @{$args->{references}}) {
    push @header, 'References' => join(' ', map { "<$_>" } @{$args->{references}});
  }
  if ($args->{replyTo}) {
    push @header, 'Reply-To' => _mkemail($args->{replyTo});
  }
  if ($args->{sender}) {
    push @header, Sender => _mkemail($args->{sender});
  }

  # Extract header:* overrides from body parts (RFC 8621 Email/set)
  for my $partlist ($args->{textBody}, $args->{htmlBody}) {
    next unless $partlist && ref($partlist) eq 'ARRAY';
    for my $part (@$partlist) {
      for my $key (keys %$part) {
        next unless $key =~ /^header:(.+)/;
        my $hname = $1;
        my $hval = $part->{$key};
        # Only add if not already set at top level
        unless (grep { lc($_) eq lc($hname) } map { $header[$_] } grep { $_ % 2 == 0 } 0..$#header) {
          push @header, $hname => $hval;
        }
      }
    }
  }

  # Extract body content from bodyValues via textBody/htmlBody part references
  my $bodyValues = $args->{bodyValues} || {};

  my $textContent;
  my $htmlContent;

  if ($args->{textBody} && ref($args->{textBody}) eq 'ARRAY') {
    for my $part (@{$args->{textBody}}) {
      my $partId = $part->{partId};
      if ($partId && $bodyValues->{$partId}) {
        $textContent = $bodyValues->{$partId}{value};
        last;
      }
      # blobId reference
      if ($part->{blobId} && $getblob) {
        my ($type, $content) = $getblob->($part->{blobId});
        $textContent = $content;
        last;
      }
    }
  }

  if ($args->{htmlBody} && ref($args->{htmlBody}) eq 'ARRAY') {
    for my $part (@{$args->{htmlBody}}) {
      my $partId = $part->{partId};
      if ($partId && $bodyValues->{$partId}) {
        $htmlContent = $bodyValues->{$partId}{value};
        last;
      }
      if ($part->{blobId} && $getblob) {
        my ($type, $content) = $getblob->($part->{blobId});
        $htmlContent = $content;
        last;
      }
    }
  }

  # Fallback: generate text from HTML if no text provided
  if (!defined $textContent && defined $htmlContent) {
    $textContent = htmltotext($htmlContent);
  }

  # Build MIME parts
  my $MIME;
  my $textpart;
  my $htmlpart;

  if (defined $textContent) {
    # Use us-ascii charset if content is pure 7-bit ASCII, UTF-8 otherwise.
    # Note: the JMAP test suite (text-body.t) is strict about expecting
    # us-ascii for plain ASCII content, even though UTF-8 is valid.
    my $charset = ($textContent =~ /[^\x{00}-\x{7f}]/) ? 'UTF-8' : 'us-ascii';
    $textpart = Email::MIME->create(
      attributes => {
        content_type => 'text/plain',
        charset => $charset,
      },
      body => $charset eq 'UTF-8' ? Encode::encode_utf8($textContent) : $textContent,
    );
  }

  if (defined $htmlContent) {
    my $charset = ($htmlContent =~ /[^\x{00}-\x{7f}]/) ? 'UTF-8' : 'us-ascii';
    $htmlpart = Email::MIME->create(
      attributes => {
        content_type => 'text/html',
        charset => $charset,
      },
      body => $charset eq 'UTF-8' ? Encode::encode_utf8($htmlContent) : $htmlContent,
    );
  }

  my @attparts;
  if ($args->{attachments} && ref($args->{attachments}) eq 'ARRAY') {
    @attparts = map { _makeatt($_, $getblob) } @{$args->{attachments}};
  }

  # Assemble the MIME structure
  if (@attparts) {
    my $body;
    if ($textpart && $htmlpart) {
      $body = Email::MIME->create(
        attributes => { content_type => 'multipart/alternative' },
        parts => [$textpart, $htmlpart],
      );
    }
    else {
      $body = $textpart || $htmlpart;
    }
    $MIME = Email::MIME->create(
      header_str => [@header, 'Content-Type' => 'multipart/mixed'],
      parts => [$body, @attparts],
    );
  }
  elsif ($textpart && $htmlpart) {
    $MIME = Email::MIME->create(
      attributes => { content_type => 'multipart/alternative' },
      header_str => \@header,
      parts => [$textpart, $htmlpart],
    );
  }
  elsif ($textpart) {
    my $cs = ($textContent =~ /[^\x{00}-\x{7f}]/) ? 'UTF-8' : 'us-ascii';
    $MIME = Email::MIME->create(
      attributes => { content_type => 'text/plain', charset => $cs },
      header_str => \@header,
      body => $cs eq 'UTF-8' ? Encode::encode_utf8($textContent) : $textContent,
    );
  }
  elsif ($htmlpart) {
    my $cs = ($htmlContent =~ /[^\x{00}-\x{7f}]/) ? 'UTF-8' : 'us-ascii';
    $MIME = Email::MIME->create(
      attributes => { content_type => 'text/html', charset => $cs },
      header_str => \@header,
      body => $cs eq 'UTF-8' ? Encode::encode_utf8($htmlContent) : $htmlContent,
    );
  }
  else {
    $MIME = Email::MIME->create(
      attributes => { content_type => 'text/plain', charset => 'us-ascii' },
      header_str => \@header,
      body => '',
    );
  }

  my $res = $MIME->as_string();
  $res =~ s/\r?\n/\r\n/gs;

  return $res;
}

sub isodate {
  my $epoch = shift || time();
  my $date = DateTime->from_epoch( epoch => $epoch );
  return $date->iso8601() . 'Z';
}

sub parse_date {
  my $date = shift;
  return str2time($date);
}

sub htmltotext {
  my $html = shift;
  my $hs = HTML::Strip->new();
  my $clean_text = $hs->parse( $html );
  $hs->eof;
  return $clean_text;
}

1;
