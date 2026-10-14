package com.roj.zen

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class IncomingCallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val peer = intent?.getStringExtra(IncomingCallActivity.EXTRA_PEER_ADDRESS)
            ?: ZenCallBridge.pendingPeerAddress
        val route = intent?.getStringExtra(IncomingCallActivity.EXTRA_ACCEPT_ROUTE)
            ?: ZenCallBridge.pendingAcceptRouteKey
        when (intent?.action) {
            ACTION_ACCEPT -> {
                ZenCallBridge.dispatchIncomingCallAction("accept", peer)
                ZenCallBridge.hideIncomingCallPopup()
                ZenCallBridge.launchMainForAccept(context.applicationContext, route, peer)
            }
            ACTION_DECLINE -> {
                ZenCallBridge.dispatchIncomingCallAction("decline", peer)
                ZenCallBridge.hideIncomingCallPopup()
            }
        }
    }

    companion object {
        const val ACTION_ACCEPT = "com.roj.zen.ACCEPT_INCOMING_CALL"
        const val ACTION_DECLINE = "com.roj.zen.DECLINE_INCOMING_CALL"
    }
}
