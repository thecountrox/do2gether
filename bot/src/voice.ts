export interface VoiceMember {
  voice: { channelId: string | null };
  user: { bot: boolean };
}

export interface BoundChannel {
  id: string;
}

export function canCreate(member: VoiceMember, channel: BoundChannel): string | null {
  if (!member.voice.channelId) return 'Join the voice call first.';
  if (member.voice.channelId !== channel.id) return 'Use the text chat of your voice call.';
  return null;
}

export function canInvite(caller: VoiceMember, target: VoiceMember, channel: BoundChannel): string | null {
  const callerReason = canCreate(caller, channel);
  if (callerReason) return callerReason;
  if (target.user.bot) return 'Bots cannot be invited.';
  if (!target.voice.channelId) return 'That user must join the voice call first.';
  if (target.voice.channelId !== channel.id) return 'That user must be in the same voice call.';
  return null;
}
