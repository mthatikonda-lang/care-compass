   System.debug('Reminders sent: ' + AppointmentReminderJob.sendTomorrowsReminders());
   System.schedule('Appointment reminders', '0 0 9 * * ?', new AppointmentReminderJob());