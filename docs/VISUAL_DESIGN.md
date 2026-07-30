# Visual Design Analysis

## Intro

My approach to designing the Conductor mobile app was to treat the desktop app as a de facto design system. I adopted its color palette, fonts, and iconography, then updated its information hierarchy, navigation, and interaction patterns to better fit both a smaller form factor and the Liquid Glass design system.

These changes ranged from things as small as increasing the corner radii of elements and adding translucent backgrounds to elements like the text field, to larger changes, such as designing the collapsible message queue.

What follows are some of the problems I faced while creating the app and the reasoning behind my solutions.

## Navigation hierarchy of Sessions (Chat tabs)

My initial navigation hierarchy used three separate screens: **Workspaces → Sessions → Chat**

After using it for a few days, I felt friction with the dedicated sessions page:

- You couldn’t see the status of other sessions when in the chat view
- It required an extra tap to get to the primary content, chat
- It didn’t match Conductor’s information priority
    - i.e. it gave sessions the same weight as workspaces and chat

Instead, I opted for a traditional tab-style approach closer to the desktop app, but with Liquid Glass styling: capsule buttons with a glass-blurred background (`.glassEffect`) in a horizontal scroll view, with the `+` button as the last item in the scroll view. 

<table align="center">
  <tr>
    <td align="center"><img src="resources/visual_design/desktop-session-tabs.png" width="400" alt="Desktop session tabs"></td>
    <td align="center"><img src="resources/visual_design/mobile-session-tabs.png" width="400" alt="Mobile session tabs"></td>
  </tr>
</table>

I opted to change the background color to indicate selection, rather than using an underline. As a result, I chose a darker color to improve contrast with the white text. 

### Session Actions

For translating the right-click menu options, I used a long-press menu (`.contextMenu`):

<p align="center">
  <img src="resources/visual_design/session-context-menu.png" width="400" alt="Session context menu">
</p>

The downside to context menus is there is nothing to visually indicate that an element can be long-pressed. As a result, iOS apps generally duplicate actions from these menus elsewhere, often in a `...` menu on the detail page for that screen (e.g. Apple Mail). This is the approach I took for the workspace actions:

<table align="center">
  <tr>
    <td align="center"><img src="resources/visual_design/workspace-more-button.png" width="250" alt="Workspace more button"></td>
    <td align="center"><img src="resources/visual_design/workspace-actions-menu.png" width="250" alt="Workspace actions menu"></td>
  </tr>
</table>

I hesitated to add the session actions to Chat’s `...` menu for two reasons:

- The menu already contains 7 actions, and this would bring it to 10, with more likely to come.
- All its actions are workspace-wide, and thus these would change its scope.

### Analysis

I am overall happy with the tab-style approach, especially with its `.glassEffect` styling, though I would love to find an alternative that takes up less vertical space. While it is usually not a problem, there are certainly some situations - such as when there are queued messages - where I wish I had the vertical space back. Even so, I believe this cost is worth the added visibility into the status of other sessions.

## Designing the message queue

My initial idea for designing the message queue was akin to iMessage & Codex, where in-flight/queued messages would be put inside of the main chat content below the active turn:

<p align="center">
  <img src="resources/visual_design/inline-queued-messages.png" width="300" alt="Inline queued messages">
</p>

However, I found this to unnecessarily clutter the chat when an agent was in progress. I thus opted for a design akin to what the desktop app does, where the queued messages are displayed above the Chat text field:

<p align="center">
  <img src="resources/visual_design/queue-action-buttons.png" width="400" alt="Queue action buttons">
</p>

However, with [Apple’s recommended minimum button hit region of 44x44 points](https://developer.apple.com/design/human-interface-guidelines/buttons#Best-practices), I found that three buttons took up too much horizontal space, while reducing their width made them difficult to tap in my testing.

As a result, I moved the actions into an “overflow” `...` menu:

<table align="center">
  <tr>
    <td align="center"><img src="resources/visual_design/queue-overflow-buttons.png" width="300" alt="Queue overflow buttons"></td>
    <td align="center"><img src="resources/visual_design/queue-action-menu.png" width="300" alt="Queue action menu"></td>
  </tr>
</table>

Whenever editing a message, rather than outlining it and changing its background color, I dimmed the other rows and replaced the `...` with the “Save edit” checkmark button:

<table align="center">
  <tr>
    <td align="center"><img src="resources/visual_design/desktop-editing-state.png" width="450" alt="Desktop editing state"></td>
    <td align="center"><img src="resources/visual_design/mobile-editing-state.png" width="300" alt="Mobile editing state"></td>
  </tr>
</table>

Although users can reorder by long-pressing and dragging the rows, I experimented with adding the system's reorder handle to make this functionality more discoverable:

<p align="center">
  <img src="resources/visual_design/queue-drag-handles.png" width="400" alt="Queue drag handles">
</p>

In my testing of it, the drag gesture felt intuitive without the handle, so I removed it to free up the horizontal space. I may need to add it back if users do not discover the drag functionality on their own without it.

### Managing the vertical space

In order to limit usage of vertical space, I followed the desktop app’s lead by truncating messages to one line and limiting the number of visible queued messages to 4. Even with these restrictions, I still found it difficult to read chat messages while multiple messages were queued. This was further exacerbated by the scroll-to-bottom button.

<table align="center">
  <tr>
    <td align="center"><img src="resources/visual_design/two-message-queue.png" width="250" alt="Two-message queue"></td>
    <td align="center"><img src="resources/visual_design/four-message-queue.png" width="250" alt="Four-message queue"></td>
    <td align="center"><img src="resources/visual_design/queue-scroll-overlap.png" width="250" alt="Queue scroll overlap"></td>
  </tr>
</table>

Thus I opted to add a collapsed state, which I placed in the same vertical slot as the scroll-to-bottom button when collapsed.

<table align="center">
  <tr>
    <td align="center"><img src="resources/visual_design/collapsed-message-queue.png" width="400" alt="Collapsed message queue"></td>
    <td align="center"><img src="resources/visual_design/collapsed-queue-scroll.png" width="400" alt="Collapsed queue with scroll control"></td>
  </tr>
</table>

Rather than automatically collapse the queue whenever the text field is focused, I let the queue shrink as the text field grows in order to prioritize the drafted message:

<table align="center">
  <tr>
    <td align="center"><img src="resources/visual_design/short-composer-queue.png" width="250" alt="Queue above a short composer"></td>
    <td align="center"><img src="resources/visual_design/tall-composer-queue.png" width="250" alt="Shrunken queue above a tall composer"></td>
  </tr>
</table>

Lastly, I gave the collapse/expand transition a bouncy spring animation to give it some extra juice (`.interactiveSpring(extraBounce: 0.5)`):

<p align="center">
  <img src="resources/visual_design/queue-collapse-animation.gif" width="300" alt="Queue collapse animation">
</p>

> Note: Since iOS 17, iOS’s default animation is a spring rather than a traditional easing curve like `easeInOut`.

I also added swipe actions for steering and deleting after moving those actions into the `...` menu:

<table align="center">
  <tr>
    <td align="center"><img src="resources/visual_design/steer-swipe-action.png" width="300" alt="Steer swipe action"></td>
    <td align="center"><img src="resources/visual_design/delete-swipe-action.png" width="300" alt="Delete swipe action"></td>
  </tr>
</table>

## Giving progress indicators semantic meaning

Conductor uses different progress indicators (aka spinners, loading indicators, etc) depending on what it is describing:

1. “horizontal” when a workspace or session is working
2. “random” for agent activity within chat
3. “pulse” when creating a cloud workspace
4. “spin” for compacting and general loading (e.g. loading a file, checks)

<table align="center">
  <thead>
    <tr>
      <th align="center">Horizontal</th>
      <th align="center">Random</th>
      <th align="center">Pulse</th>
      <th align="center">Spinner</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center"><img src="resources/visual_design/workspace-activity-indicator.gif" width="150" alt="Horizontal workspace activity indicator"></td>
      <td align="center"><img src="resources/visual_design/agent-activity-indicator.gif" width="150" alt="Random agent activity indicator"></td>
      <td align="center"><img src="resources/visual_design/conductor-create-workspace.gif" width="150" alt="Cloud workspace creation indicator"></td>
      <td align="center"><img src="resources/visual_design/conductor-ring-spinner.gif" width="150" alt="Conductor spinner"></td>
    </tr>
  </tbody>
</table>

Thus I initially reached for the “spin” animation when I needed to represent network activity in the app, e.g. connecting to the desktop companion and cloud or loading chat transcripts:

<table align="center">
  <tr>
    <td align="center"><img src="resources/visual_design/header-conductor-spinner.gif" width="450" alt="Header Conductor spinner"></td>
    <td align="center"><img src="resources/visual_design/chat-conductor-spinner.gif" width="300" alt="Chat Conductor spinner"></td>
  </tr>
</table>

When I used the app while traveling with a poor connection, I found the "spin" animation confusing when sending a message or loading a chat. Even though I _knew_ the network was causing the delay, it still felt like it was the app or Conductor itself that was causing the delay.

As a result, I opted to use the system progress indicator for any loading that was purely network-related, and kept Conductor's indicators for compaction, agent activity, and other non-network loading states.

<table align="center">
  <tr>
    <td align="center"><img src="resources/visual_design/header-network-spinner.gif" width="450" alt="Header network spinner"></td>
    <td align="center"><img src="resources/visual_design/chat-network-spinner.gif" width="300" alt="Chat network spinner"></td>
  </tr>
</table>

I don't necessarily think the system progress indicator is the final answer. I used it because it was the only available indicator that looked different enough from Conductor's existing animations to convey that the delay is coming from the network rather than Conductor. 
